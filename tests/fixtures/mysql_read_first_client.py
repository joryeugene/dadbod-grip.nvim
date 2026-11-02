#!/usr/bin/python3
"""Controlled source-denial/commit protocol; real child lifecycle, no DB claims."""
import json, os, re, signal, sys, time
from pathlib import Path
root, mode = Path(sys.argv[1]), sys.argv[2]
root.mkdir(exist_ok=True)
path = root / str(os.getpid())
path.mkdir()
(path / 'pid').write_text(str(os.getpid()))
(path / 'argv').write_text(json.dumps(sys.argv))
(path / 'password').write_text(os.environ.get('MYSQL_PWD', ''))
if mode.endswith('hang'):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
original_seen = False
def text(value):
    return 'N' if value is None else 'T' + value.encode().hex().upper()
with (path / 'stdin').open('w') as log:
    for line in sys.stdin:
        log.write(line)
        log.flush()
        original_seen = original_seen or 'DERIVED_ORIGINAL_SECRET' in line
        header_sql = 'SHOW HEADER' in line or 'FROM information_schema.TABLES' in line and not original_seen
        post_sql = 'SHOW POST' in line or 'FROM information_schema.TABLES' in line and original_seen
        profile_sql = "SELECT CONCAT('V|'" in line
        witness_sql = 'SHOW CREATE TABLE' in line
        stage = 'post' if original_seen else 'header'
        denied = (header_sql and mode == 'header-deny'
                  or post_sql and mode == 'post-deny'
                  or 'COMMIT;' in line and mode == 'commit-deny'
                  or 'DERIVED_ORIGINAL_SECRET' in line and mode == 'original-deny'
                  or profile_sql and mode == stage + '-profile-deny'
                  or witness_sql and mode == stage + '-witness-deny')
        if denied:
            sys.stderr.write('ERROR 1142 (42000): synthetic ' + mode + '\n')
            sys.exit(1)
        if ('DERIVED_ORIGINAL_SECRET' in line and mode == 'original-hang'
                or post_sql and mode == 'post-hang'
                or 'COMMIT;' in line and mode == 'commit-hang'):
            (root / 'ready').write_text('ready')
            while True:
                time.sleep(1)
        match = re.fullmatch(r"SELECT '([a-zA-Z0-9_]+)';\n", line)
        if match:
            marker = match[1]
            if marker.endswith('_ROWS_END'):
                print('X0' if mode == 'malformed' else 'X31')
                print('1\nWarning\t1265\tData truncated' if mode == 'warning' else '0')
            print(marker, flush=True)
        if 'SHOW HEADER' in line or 'SHOW POST' in line:
            print('metadata', flush=True)
        elif "SELECT CONCAT('I|'" in line:
            print('I|' + str(os.getpid()) + '|' + text('fixture'), flush=True)
        elif 'FROM information_schema.TABLES' in line:
            print('S|' + '|'.join(map(text, ['fixture', 'tasks', 'BASE TABLE', 'InnoDB', 'utf8mb4_bin'])), flush=True)
        elif 'FROM information_schema.COLUMNS' in line:
            print('C|1|' + '|'.join(map(text, ['id', 'int', 'int', 'NO', None, 'PRI', '', None, None, '', 'fixture', 'tasks', ''])), flush=True)
        elif profile_sql:
            quote = '0' if mode == ('post' if original_seen else 'pre') + '-quote-off' else '1'
            print('V|' + '|'.join(map(text, ['8.4.6', 'MySQL Community Server - GPL', quote, 'ANSI_QUOTES,NO_BACKSLASH_ESCAPES'])), flush=True)
        elif "SHOW VARIABLES LIKE 'show_gipk" in line:
            flag = 'OFF' if mode == ('post' if original_seen else 'pre') + '-gipk-off' else 'ON'
            print('show_gipk_in_create_table_and_information_schema\t' + flag, flush=True)
        elif witness_sql:
            extra = ',\\n  `hidden_tail` int' if mode == ('post' if original_seen else 'pre') + '-layout-prefix' else ''
            print('tasks\tCREATE TABLE `tasks` (\\n  `id` int NOT NULL' + extra + ',\\n  PRIMARY KEY (`id`)\\n) ENGINE=InnoDB', flush=True)
        elif "SELECT CONCAT('W|'" in line:
            print('W|0', flush=True)
if original_seen and mode == 'completion-deny':
    sys.stderr.write('synthetic failure after COMMIT acknowledgement\n')
    sys.exit(1)
if original_seen and mode == 'completion-hang':
    while True:
        time.sleep(1)
