module order 2025;
/// The DTO of the JSON benchmarks and the `std.json` way of reading and writing it (`std.json` has no typed decoding or
/// encoding: parse the tree, copy it into the struct; build a tree to write).
import std.conv : to;
import std.json : JSONValue, parseJSON;

struct Item { long id; string name; double price; bool active; string[] tags; }
struct Order { long id; string customer; Item[] items; }

Order sample()
{
    Order o = Order(1042, "Ada Lovelace");
    foreach (i; 0 .. 20)
        o.items ~= Item(i + 1, "widget-" ~ i.to!string, 9.5 + i, i % 2 == 0, ["a", "b", "tag-" ~ i.to!string]);
    return o;
}

Order viaStd(string text)
{
    auto j = parseJSON(text);
    Order o;
    o.id = j["id"].integer;
    o.customer = j["customer"].str;
    foreach (ref e; j["items"].array)
    {
        Item it;
        it.id = e["id"].integer;
        it.name = e["name"].str;
        it.price = e["price"].floating;
        it.active = e["active"].boolean;
        foreach (ref t; e["tags"].array)
            it.tags ~= t.str;
        o.items ~= it;
    }
    return o;
}

string toStd(const Order o)
{
    JSONValue j = ["id": JSONValue(o.id), "customer": JSONValue(o.customer)];
    JSONValue[] items;
    foreach (ref it; o.items)
    {
        JSONValue[] tags;
        foreach (t; it.tags)
            tags ~= JSONValue(t);
        items ~= JSONValue(["id": JSONValue(it.id), "name": JSONValue(it.name), "price": JSONValue(it.price),
            "active": JSONValue(it.active), "tags": JSONValue(tags)]);
    }
    j["items"] = JSONValue(items);
    return j.toString;
}
