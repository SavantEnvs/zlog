# zlog_init(): NULL / dangling `process_data.logc` when the writer-thread consumer fails to start

Reproducer: `null-logc-on-init-failure.conf` (`mayhem/zlog_init_fuzzer-standalone <conf>`).

**Cause.** With `use_writer_thread = 1`, `zlog_init_inner()` (src/zlog.c) calls `log_consumer_create()`. It
fails when the conf is inconsistent, for example `buffer max` below `buffer min` (`zlog_buf_new fail`). The
error path runs `zlog_fini_inner()`, which sees `zlog_env_conf->log_consumer.en` and calls
`log_consumer_destroy(process_data.logc)` although no consumer was stored. In a fresh process that is a NULL
dereference (`consumer.c:37`, UBSan). After an earlier successful `zlog_init()`/`zlog_fini()` the pointer is
the old, already freed consumer: a heap-use-after-free in `enque_event_exit` (ASan), reached by the fuzzer
within a minute.

**Impact.** A logging library crashes while rejecting a bad configuration. `zlog_reload()` has the same shape.

**Fix.** Store `process_data.logc` only on success and reset it to NULL in `zlog_fini_inner()` after the
destroy, or guard `log_consumer_destroy(NULL)`.

Also found while porting: `zlog_init_from_string()` (`zlog_init_inner_from_string`) never creates the
consumer, so `zlog_init_from_string()` + `zlog_fini()` with `use_writer_thread = 1` hits the same NULL
destroy on every call. The harness therefore uses `zlog_init()` on a scratch file.
