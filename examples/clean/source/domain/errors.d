/// The errors of the business rules. Use cases throw them; `app.d` maps each one to an HTTP status, so the core never
/// mentions one.
module domain.errors;

@safe:

/// A business rule said no.
class DomainError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
    }
}

/// What was asked for does not exist (HTTP 404).
class NotFound : DomainError
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
    }
}

/// It clashes with what exists, such as a value that must be unique (HTTP 409).
class Conflict : DomainError
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
    }
}

/// The input breaks a business rule (HTTP 422).
class RuleViolation : DomainError
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
    }
}
