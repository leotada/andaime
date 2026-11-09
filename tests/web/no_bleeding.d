/// Nothing a handler receives points into the request buffer: the buffer is reused by the next request, so a value kept
/// past the request must not change when the buffer does. Each test builds the request over mutable buffers, runs the
/// real dispatch, overwrites every buffer with 'X' (the next patient's request) and checks what the handler kept.
module no_bleeding 2025;

@safe:

import andaime;
import andaime.http : splitTarget;
import andaime.http.types : HeaderField;

/// A text type that holds a slice: it must get a copy, whatever its own `fromString` does.
struct PatientId
{
    string text;

    static bool fromString(scope const(char)[] t, out PatientId v)
    {
        v.text = t.idup;
        return t.length > 0;
    }

    void toString(scope void delegate(scope const(char)[]) @safe sink) const { sink(text); }
}

struct Prescription
{
    string drug;
    const(char)[] dose;
    string[] notes;
    string[string] extra;
    JsonValue anything;
    PatientId patient;
}

struct Intake
{
    string name;
    const(char)[] ward;
    PatientId patient;
}

struct Exam
{
    string title;
    UploadedFile report;
    UploadedFile[] scans;
}

// What the handlers kept (thread-local: the tests run on one thread).
const(char)[] keptSlug, keptQ, keptCookie;
string keptS, keptHeader;
PatientId keptWho;
Prescription keptRx;
Intake keptIntake;
Exam keptExam;

string byPath(const(char)[] slug, const(char)[] q, string s, PatientId who, Header!"X-Ward" ward, Cookie!"session" session)
{
    keptSlug = slug;
    keptQ = q;
    keptS = s;
    keptWho = who;
    keptHeader = ward.value;
    keptCookie = session.value;
    return "ok";
}

string prescribe(JsonBody!Prescription rx)
{
    keptRx = rx.value;
    return "ok";
}

string intake(Form!Intake f)
{
    keptIntake = f.value;
    return "ok";
}

string exam(Form!Exam f)
{
    keptExam = f.value;
    return "ok";
}

App build()
{
    auto app = new App;
    app.get!("/p/{slug}", byPath);
    app.post!("/rx", prescribe);
    app.post!("/intake", intake);
    app.post!("/exam", exam);
    return app;
}

/// Runs one request built over buffers of its own, then scribbles over all of them.
private int send(App app, Method method, string target, string body_ = null, string contentType = null,
    string[2][] headers = null)
{
    char[] targetBuf = target.dup;
    char[] bodyBuf = body_.dup;
    char[][] valueBufs;
    Request req;
    req.method = method;
    req.target = targetBuf;
    splitTarget(req.target, req.path, req.query);
    req.body = cast(const(ubyte)[]) bodyBuf;
    if (contentType.length)
    {
        valueBufs ~= contentType.dup;
        req.headers ~= HeaderField("content-type", valueBufs[$ - 1]);
    }
    foreach (h; headers)
    {
        valueBufs ~= h[1].dup;
        req.headers ~= HeaderField(h[0], valueBufs[$ - 1]);
    }

    auto ctx = new Context;
    ctx.reset(req);
    app.handle(ctx);
    immutable status = ctx.response.status;

    // the next request reuses the buffers
    targetBuf[] = 'X';
    bodyBuf[] = 'X';
    foreach (b; valueBufs)
        b[] = 'X';
    return status;
}

unittest
{
    auto app = build();
    assert(send(app, Method.GET, "/p/ana-silva?q=insulin&s=bed%2012&who=P-0042",
        null, null, [["x-ward", "cardiology"], ["cookie", "session=abc123; theme=dark"]]) == 200);

    // path, query (plain and percent-decoded), a text type that holds a slice, a header, a cookie
    assert(keptSlug == "ana-silva", keptSlug);
    assert(keptQ == "insulin", keptQ);
    assert(keptWho.text == "P-0042", keptWho.text);
    assert(keptHeader == "cardiology", keptHeader);
    assert(keptCookie == "abc123", keptCookie);
}

unittest
{
    auto app = build();
    assert(send(app, Method.POST, "/rx", `{"drug":"insulin","dose":"10 UI","notes":["fasting","a\nb"],`
        ~ `"extra":{"room":"12B"},"anything":{"k":["v"]},"patient":"P-0042"}`, "application/json") == 200);

    // every string field, the slice-typed one, the arrays, the map keys and values, a JsonValue and the text type
    assert(keptRx.drug == "insulin", keptRx.drug);
    assert(keptRx.dose == "10 UI", keptRx.dose);
    assert(keptRx.notes == ["fasting", "a\nb"], keptRx.notes[0]);
    assert(keptRx.extra == ["room": "12B"]);
    assert(keptRx.anything.toString == `{"k":["v"]}`, keptRx.anything.toString);
    assert(keptRx.patient.text == "P-0042", keptRx.patient.text);
}

unittest
{
    auto app = build();
    // urlencoded: a string field, a slice-typed field (percent-decoded or not) and a text type
    assert(send(app, Method.POST, "/intake", "name=Joao+da+Silva&ward=icu&patient=P-0042",
        "application/x-www-form-urlencoded") == 200);
    assert(keptIntake.name == "Joao da Silva", keptIntake.name);
    assert(keptIntake.ward == "icu", keptIntake.ward);
    assert(keptIntake.patient.text == "P-0042", keptIntake.patient.text);

    // multipart text parts
    keptIntake = Intake.init;
    string mp = "--z\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nMaria\r\n"
        ~ "--z\r\nContent-Disposition: form-data; name=\"ward\"\r\n\r\nward-7\r\n"
        ~ "--z\r\nContent-Disposition: form-data; name=\"patient\"\r\n\r\nP-0099\r\n--z--\r\n";
    assert(send(app, Method.POST, "/intake", mp, "multipart/form-data; boundary=z") == 200);
    assert(keptIntake.name == "Maria", keptIntake.name);
    assert(keptIntake.ward == "ward-7", keptIntake.ward);
    assert(keptIntake.patient.text == "P-0099", keptIntake.patient.text);
}

unittest
{
    auto app = build();
    // an uploaded file is the sensitive case: its bytes are a view of the request body, which the pool reuses
    string mp = "--z\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nChest x-ray\r\n"
        ~ "--z\r\nContent-Disposition: form-data; name=\"report\"; filename=\"joao.pdf\"\r\n"
        ~ "Content-Type: application/pdf\r\n\r\n%PDF-patient-joao\r\n"
        ~ "--z\r\nContent-Disposition: form-data; name=\"scans\"; filename=\"a.png\"\r\n\r\nscan-A\r\n"
        ~ "--z\r\nContent-Disposition: form-data; name=\"scans\"; filename=\"b.png\"\r\n\r\nscan-B\r\n--z--\r\n";
    assert(send(app, Method.POST, "/exam", mp, "multipart/form-data; boundary=z") == 200);
    assert(keptExam.title == "Chest x-ray", keptExam.title);
    assert(keptExam.report.filename == "joao.pdf" && keptExam.report.contentType == "application/pdf");
    assert(keptExam.report.bytes == cast(const(ubyte)[]) "%PDF-patient-joao", "an uploaded file changed with the buffer");
    assert(keptExam.scans.length == 2);
    assert(keptExam.scans[0].bytes == cast(const(ubyte)[]) "scan-A");
    assert(keptExam.scans[1].bytes == cast(const(ubyte)[]) "scan-B");
}
