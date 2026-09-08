# tools/test/test-linux-metrics-aggregation-native.py
"""Small real-SQLite equivalence fixture; requires Linux LuaJIT and sqlite3."""
import datetime
import pathlib
import sqlite3
import subprocess
import tempfile
from contextlib import closing

root = pathlib.Path(__file__).resolve().parents[2]
tables = ['ngram_chars', 'ngram_bigrams', 'ngram_trigrams', 'ngram_quadgrams',
          'ngram_pentagrams', 'ngram_hexagrams', 'ngram_heptagrams',
          'ngram_words', 'ngram_word_bigrams']
sources = ['{}', '{"hotstring":2,"llm":3,"other":4}',
           '{"hotstring":"5","llm":-2,"other":1.5}',
           'broken "hotstring":7,"llm":8,"other":9', '', 'null',
           '{"unknown":44}', '{ "hotstring": 2, "llm": 3, "other": 4 }',
           '{"hotstring":0.1,"llm":0.1,"other":0.1}']
with tempfile.TemporaryDirectory(prefix='ergopti-aggregation-regression-') as temporary:
    database = pathlib.Path(temporary) / 'fixture.sqlite'
    with closing(sqlite3.connect(database)) as connection:
        connection.executescript((root / 'static/ergopti_plus/_shared/data/db/schema.sql').read_text())
        for table in tables:
            for day in ['2020-01-01', datetime.date.today().isoformat()]:
                for app in ['app-a', 'app-b']:
                    for index, source in enumerate(sources):
                        for copy in range(3):
                            connection.execute(f'INSERT INTO {table}(device_id,date,app,token,c,td,e,esrc_json) VALUES (?,?,?,?,?,?,?,?)',
                                               (f'device-{index}-{copy}', day, app, 'token', copy + 1, copy * 10, copy, source))
            for copy in range(3):
                connection.execute(f'INSERT INTO {table}(device_id,date,app,token,c,td,e,esrc_json) VALUES (?,?,?,?,?,?,?,?)',
                                   (f'extreme-{copy}', '2020-01-01', 'app-a', 'extreme', 9223372036854775807, 9223372036854775807, 0, '{}'))
            for day in ['2020-01-01', datetime.date.today().isoformat()]:
                connection.execute(f'INSERT INTO {table}(device_id,date,app,token,c,td,e,esrc_json) VALUES (?,?,?,?,?,?,?,?)',
                                   ('malformed-number', day, 'app-a', 'anomaly', '12oops', '0x10', '2oops', '{"hotstring":0.1}'))
            connection.commit()
    subprocess.run(['luajit', str(root / 'tools/test/linux-metrics-aggregation-native.lua'), str(root), str(database)],
                   check=True, timeout=90)
