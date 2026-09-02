/*
 * C interface to the shared IndeRun route-planning core.
 *
 * Hand-written rather than generated: the surface is two functions and has to
 * stay in sync with `src/ffi.rs`, where the same two symbols are defined with
 * `#[unsafe(no_mangle)] pub unsafe extern "C"`. Adding a symbol there means
 * adding it here.
 *
 * This header is packaged into the XCFramework built by
 * `scripts/build-route-core-apple.mjs` and is how the Swift SDK reaches the
 * planner. Android uses the JNI entry point instead and does not need it.
 */

#ifndef INDERUN_ROUTE_CORE_H
#define INDERUN_ROUTE_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Plans a route. `input_json` is a NUL-terminated RoutePlannerInput JSON
 * document; the result is a NUL-terminated RoutePlan JSON document.
 *
 * Never returns NULL for a non-NULL input: malformed input and planner errors
 * come back as a well-formed RoutePlan with `failureCode: "unavailable"` and
 * the reason in `explanation.summary`, so callers decode one shape either way.
 *
 * The caller owns the returned buffer and must release it with
 * `inderun_free_string`. Freeing it any other way is undefined: it was
 * allocated by Rust.
 */
char *inderun_plan_route_json(const char *input_json);

/*
 * Releases a string previously returned by `inderun_plan_route_json`.
 * NULL-safe. Passing anything else, or the same pointer twice, is undefined.
 */
void inderun_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif /* INDERUN_ROUTE_CORE_H */
