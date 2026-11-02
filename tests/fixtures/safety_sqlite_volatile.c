/* Reviewer-authored scalar fixture: records every actual SQLite evaluation. */
#include <sqlite3ext.h>
#include <stdio.h>
#include <stdlib.h>
SQLITE_EXTENSION_INIT1
static unsigned evaluations;
static void value(sqlite3_context *context, int argc, sqlite3_value **argv) {
  const char *path = getenv("GRIP_REVIEW_COUNTER_FILE");
  FILE *file = path ? fopen(path, "ab") : NULL;
  (void)argc; (void)argv;
  if (!file) { sqlite3_result_error(context, "missing private counter", -1); return; }
  fputc('x', file); fclose(file);
  if (++evaluations % 2) sqlite3_result_blob(context, "AB", 2, SQLITE_STATIC);
  else sqlite3_result_int(context, 7);
}
int sqlite3_extension_init(sqlite3 *db, char **error, const sqlite3_api_routines *api) {
  (void)error;
  SQLITE_EXTENSION_INIT2(api);
  return sqlite3_create_function(db, "grip_review_value", 0, SQLITE_UTF8, NULL, value, NULL, NULL);
}
