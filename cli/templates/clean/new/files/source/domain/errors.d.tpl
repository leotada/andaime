/// The errors of the business rules. Use cases throw them; `app.d` maps each one to an HTTP status, so the core never
/// mentions one. `code` is the machine-readable part of the answer (`adapters/http/errors.d`).
module domain.errors 2025;

@safe:

/// A business rule said no.
class DomainError : Exception
{
    /// What a client can test for: "not_found", "conflict", "rule_violation", or a more specific one.
    string code;

    this(string msg, string code = "rule_violation", string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
        this.code = code;
    }
}

/// What was asked for does not exist (HTTP 404).
class NotFound : DomainError
{
    this(string msg, string code = "not_found", string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, code, file, line);
    }
}

/// It clashes with what exists, such as a value that must be unique (HTTP 409).
class Conflict : DomainError
{
    this(string msg, string code = "conflict", string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, code, file, line);
    }
}

/// The one acting may not do this (HTTP 403): a permission the domain's policies refuse.
class Forbidden : DomainError
{
    this(string msg, string code = "forbidden", string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, code, file, line);
    }
}

/// The input breaks a business rule (HTTP 422).
class RuleViolation : DomainError
{
    this(string msg, string code = "rule_violation", string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, code, file, line);
    }
}
