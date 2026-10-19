/// The body of every error the API answers: a domain error, a validation error, a missing route, a failure. One format,
/// set once in `app.d` with `app.errorBody(&apiError)`.
module adapters.http.errors 2025;

@safe:

import andaime;
import domain.errors : DomainError;

/// `{"message": "...", "code": "..."}`: a sentence for people, a code for programs.
struct ApiError
{
    string message;
    string code;
}

/// The answer to one error (see `ErrorInfo`): a domain error keeps its own code; the others get one from their status.
ApiError apiError(ref const ErrorInfo e)
{
    if (auto d = cast(const DomainError) e.exception)
        return ApiError(e.message, d.code);
    switch (e.status)
    {
        case 404: return ApiError(e.message, "not_found");
        case 405: return ApiError(e.message, "method_not_allowed");
        case 422: return ApiError(e.message, "invalid_request");
        case 500: return ApiError(e.message, "internal_error");
        default: return ApiError(e.message, "error");
    }
}
