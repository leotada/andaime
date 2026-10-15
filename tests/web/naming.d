/// Wire names: `@naming` on a struct (JSON, `Query!T`, `Form!T`, OpenAPI) and on an enum, `@wireName` on an enum member.
module naming_test;

@safe:

import vela;
import vela.web.testing;
import std.json : parseJSON;

@naming(Naming.kebabCase)
enum TaskType { task, taskInstance, workflowInstance }

enum Photo { none, @wireName("on_issue") onIssue, always }

@naming(Naming.snakeCase)
struct Assignee
{
    long userId;
    string displayName;
}

@naming(Naming.snakeCase)
struct TaskIn
{
    string firstName;
    long companyId;
    @jsonKey("assigned") Optional!Assignee assignedTo; // a field's @jsonKey wins
    TaskType taskType = TaskType.task;
    Photo photo;
    string body_;                                    // the trailing `_` (a D keyword escape) is dropped
}

@naming(Naming.snakeCase)
struct Filters
{
    string[] tagIds;
    int pageSize = 20;
    Optional!TaskType taskType;
}

@naming(Naming.snakeCase)
struct Login { string userName; string passWord; }

TaskIn echo(JsonBody!TaskIn t) => t.value;
string list(Query!Filters f) => f.tagIds.length ? f.tagIds[0] ~ "/" ~ (f.taskType.has ? "set" : "-") : "none";
string login(Form!Login f) => f.userName ~ ":" ~ f.passWord;
string byType(TaskType kind) => kind == TaskType.workflowInstance ? "wf" : "other";

App build()
{
    auto app = new App;
    app.post!("/tasks", echo);
    app.get!("/tasks", list);
    app.post!("/login", login);
    app.get!("/types/{kind}", byType);
    app.serveOpenApi(OpenApiInfo("N", "1"));
    return app;
}

unittest
{
    auto c = TestClient(build());

    // JSON both ways: snake_case keys, enums by wire name, the field's @jsonKey kept, nested struct with its own policy
    auto r = c.post("/tasks", `{"first_name":"Ana","company_id":7,"assigned":{"user_id":3,"display_name":"Bo"},`
        ~ `"task_type":"task-instance","photo":"on_issue","body":"x"}`, hdr("Content-Type", "application/json"));
    assert(r.status == 200, r.body);
    assert(r.body == `{"first_name":"Ana","company_id":7,"assigned":{"user_id":3,"display_name":"Bo"},`
        ~ `"task_type":"task-instance","photo":"on_issue","body":"x"}`, r.body);

    // the D name is not accepted anymore, and the error speaks wire names
    r = c.post("/tasks", `{"firstName":"Ana","company_id":7,"task_type":"taskInstance","photo":"onIssue","body":""}`,
        hdr("Content-Type", "application/json"));
    assert(r.status == 422);
    assert(r.body == `{"detail":[`
        ~ `{"type":"enum","loc":["body","task_type"],"msg":"expected one of: task, task-instance, workflow-instance"},`
        ~ `{"type":"enum","loc":["body","photo"],"msg":"expected one of: none, on_issue, always"},`
        ~ `{"type":"missing","loc":["body","first_name"],"msg":"Field required"}]}`, r.body);
}

unittest
{
    auto c = TestClient(build());

    // Query!T and Form!T use the same names
    assert(c.get("/tasks?tag_ids=a&tag_ids=b&task_type=workflow-instance").body == "a/set");
    auto r = c.get("/tasks?page_size=x");
    assert(r.status == 422 && r.body == `{"detail":[{"type":"int_parsing","loc":["query","page_size"],`
        ~ `"msg":"expected an integer between -2147483648 and 2147483647"}]}`, r.body);
    assert(c.post("/login", "user_name=ana&pass_word=x", hdr("Content-Type", "application/x-www-form-urlencoded")).body
        == "ana:x");

    // a path parameter
    assert(c.get("/types/workflow-instance").body == "wf");
    assert(c.get("/types/workflowInstance").status == 422);
}

@system unittest // (std.json's object/array accessors are @system)
{
    auto c = TestClient(build());
    auto doc = parseJSON(c.get("/openapi.json").body);
    auto task = doc["components"]["schemas"]["TaskIn"];
    assert("first_name" in task["properties"].object && "assigned" in task["properties"].object
        && "body" in task["properties"].object, task.toString);
    auto tt = task["properties"]["task_type"];
    assert(tt["enum"].toString == `["task","task-instance","workflow-instance"]`, tt.toString);

    string[] names;
    foreach (p; doc["paths"]["/tasks"]["get"]["parameters"].array)
        names ~= p["name"].str;
    assert(names == ["tag_ids", "page_size", "task_type"], names[0]);
}
