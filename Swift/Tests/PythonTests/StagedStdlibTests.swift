import Testing
@testable import Python

// Every optional module build.sh stages imports, and the C ones work.
@MainActor @Suite(.serialized) struct StagedStdlibTests {
    @Test func everythingImports() throws {
        try PyRuntime.initialize()
        try PyRuntime.run("""
        import sys, importlib
        names = '''string timeit statistics decimal pprint difflib shutil glob fnmatch tempfile calendar
        gettext locale base64 struct csv pickle tarfile gzip plistlib configparser ipaddress mimetypes shlex
        graphlib colorsys hashlib hmac secrets uuid argparse threading queue urllib.parse html
        html.parser tomllib zoneinfo zipfile sqlite3 xml.etree.ElementTree xml.dom.minidom unittest logging
        concurrent.futures array cmath unicodedata pyexpat binascii'''.split()
        failed = []
        for n in names:
            try: importlib.import_module(n)
            except Exception as e: failed.append(f'{n}: {type(e).__name__}: {e}')
        # C modules doing real work
        import hashlib, sqlite3, struct, csv, io, base64, unicodedata, zipfile, json, decimal, statistics, timeit
        assert hashlib.md5(b'x').hexdigest() == '9dd4e461268c8034f5c8564e155c67a6'
        assert hashlib.sha1(b'x').hexdigest().startswith('11f6ad8')
        assert hashlib.sha3_256(b'x').hexdigest().startswith('741efa3')
        assert hashlib.blake2b(b'x').hexdigest()
        con = sqlite3.connect(':memory:'); con.execute('create table t(a)'); con.execute('insert into t values (42)')
        assert con.execute('select a from t').fetchone() == (42,)
        assert struct.pack('<I', 1) == b'\\x01\\x00\\x00\\x00'
        assert list(csv.reader(io.StringIO('a,b\\n1,2\\n'))) == [['a','b'],['1','2']]
        assert base64.b64encode(b'hi') == b'aGk='
        assert unicodedata.name('é') == 'LATIN SMALL LETTER E WITH ACUTE'
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z: z.writestr('a.txt', 'hello')
        with zipfile.ZipFile(io.BytesIO(buf.getvalue())) as z: assert z.read('a.txt') == b'hello'
        import xml.etree.ElementTree as ET
        assert ET.fromstring('<a><b>1</b></a>').find('b').text == '1'
        assert 'hello'.encode('utf-16').decode('utf-16') == 'hello'
        assert 'ö'.encode('cp1252') == b'\\xf6'
        assert statistics.mean([1, 2, 3]) == 2 and decimal.Decimal('0.1') + decimal.Decimal('0.2') == decimal.Decimal('0.3')
        assert timeit.timeit('1+1', number=10) >= 0
        import zoneinfo; zoneinfo.ZoneInfo('Europe/Budapest')
        # Loaded from the zip as bytecode, docstrings and signatures intact.
        assert json.__spec__.origin.endswith('stdlib.zip/json/__init__.pyc'), json.__spec__.origin
        assert 'Serialize' in json.dumps.__doc__ and str(__import__('inspect').signature(json.dumps)).startswith('(obj, *,')
        assert not failed, failed
        """)
    }
}
