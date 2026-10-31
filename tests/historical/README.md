# Historical transport evidence

`mysql_temp_read_denial_spec.lua` preserves the original T01 regression byte for byte. It checks the removed CTAS reader's TEMP capability preflight and is not an acceptance test for the read-first transport.

The active `mysql_read_first_process_spec.lua` tests actual header, original-read, post-read metadata, COMMIT and completion failures, including cleanup and no replay. The independent positive T02/T03/T04/T05 native cases remain unchanged in `tests/spec/safety_adversarial_mysql_read_live_spec.lua`.
