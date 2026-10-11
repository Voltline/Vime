#!/usr/bin/env python3
"""Build bounded JMdict-derived spelling and colloquial packs; no network at runtime.

Usage: python3 Scripts/build_language_resources.py /path/to/JMdict_e.gz
Download upstream from https://www.edrdg.org/pub/Nihongo/JMdict_e.gz.
Generated JMdict derivatives are CC BY-SA 4.0, independently of Vime code.
"""
import gzip
import hashlib
import json
import re as regex
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

OUT = Path(__file__).resolve().parents[1] / 'Shared/Resources'
SOURCE = 'https://www.edrdg.org/pub/Nihongo/JMdict_e.gz'
OFFICIAL = 'https://www.bunka.go.jp/seisaku/bunkashingikai/kokugo/hokoku/pdf/93731901_01.pdf'


def kana(text):
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in text)


def build(path):
    payload = path.read_bytes()
    xml = gzip.decompress(payload)
    root = ET.fromstring(xml)
    spelling, lexicon = {}, {}
    # Standalone forms only. Auxiliary/formal-noun rules need sense/context
    # disambiguation and are deliberately not global substitutions.
    for reading, surface in [('ありがとう', '有難う'), ('おはよう', 'お早う'),
        ('こんにちは', '今日は'), ('さすが', '流石'), ('ちょっと', '一寸'),
        ('たばこ', '煙草'), ('ふだん', '普段'), ('めった', '滅多')]:
        spelling[reading] = dict(reading=reading, preferred=reading, alternatives=[surface],
            authority='publicWriting', source=OFFICIAL, evidence='公用文・当て字/挨拶', weight=1.6)
    for entry in root:
        eid = entry.findtext('ent_seq')
        senses = entry.findall('sense')
        tags = {n.text for s in senses for n in s.findall('misc')}
        forbidden = {'archaic', 'obsolete term', 'dated term', 'vulgar expression or word', 'derogatory'}
        if tags & forbidden:
            continue
        # Avoid importing inflected verbs with an incorrect noun connection ID.
        nouns = any(n.text == 'noun (common) (futsuumeishi)' for s in senses for n in s.findall('pos'))
        surfaces = [n.findtext('keb') for n in entry.findall('k_ele')]
        has_hiragana = any(any('ぁ' <= c <= 'ゖ' for c in re.findtext('reb', '')) for re in entry.findall('r_ele'))
        for re in entry.findall('r_ele'):
            reading = kana(re.findtext('reb', ''))
            preferred = reading if has_hiragana else re.findtext('reb', reading)
            if not 2 <= len(reading) <= 16 or not all('ぁ' <= c <= 'ゖ' or c == 'ー' for c in reading):
                continue
            restrict = {n.text for n in re.findall('re_restr')}
            compatible = [s for s in surfaces if not restrict or s in restrict]
            applicable = [s for s in senses if (not s.findall('stagr') or re.findtext('reb') in {n.text for n in s.findall('stagr')})
                and not s.findall('stagk')]
            usually_kana = bool(applicable) and all(any(n.text == 'word usually written using kana alone'
                for n in s.findall('misc')) for s in applicable)
            # Bound automatic style preferences to unambiguous noun entries.
            if nouns and compatible and usually_kana and len(reading) <= 10:
                spelling.setdefault(reading, dict(reading=reading, preferred=preferred,
                    alternatives=sorted(set(compatible)), authority='dictionaryUsage', source=SOURCE,
                    entry=eid, common=bool(re.findall('re_pri')), evidence='JMdict uk / restricted senses excluded', weight=1.2))
            # 怪我 is ateji, not uk. The general public-writing rule and the
            # attested entry establish this preference; never claim uk evidence.
            if nouns and any(n.text == 'ateji (phonetic) reading' for k in entry.findall('k_ele') for n in k.findall('ke_inf')):
                spelling.setdefault(reading, dict(reading=reading, preferred=preferred, alternatives=sorted(set(compatible)),
                    authority='atejiGuidance', source=OFFICIAL, dictionaryEntry=eid,
                    common=bool(re.findall('re_pri')), evidence='公用文当て字方針 + JMdict ateji', weight=1.4))
            if nouns and tags & {'Internet slang', 'slang', 'manga slang', 'colloquial', 'abbreviation'}:
                for surface in (compatible or [re.findtext('reb')])[:2]:
                    if surface and len(surface) <= 20:
                        lexicon[(reading, surface)] = dict(reading=reading, surface=surface, entry=eid,
                            tags=sorted(tags), source=SOURCE, value=-18.0)
    # Internet-tagged entries come first; deterministic limits and no foreign POS IDs.
    words = sorted(lexicon.values(), key=lambda x: ('Internet slang' not in x['tags'],
        'slang' not in x['tags'], 'manga slang' not in x['tags'], 'colloquial' not in x['tags'],
        x['reading'], x['surface']))[:2000]
    styles = sorted(sorted(spelling.values(), key=lambda x:
        (x['authority'] != 'publicWriting', not x.get('common', False), x['reading']))[:2000], key=lambda x: x['reading'])
    packs = {'OrthographyPreferences.json': styles, 'SupplementalLexicon.json': words}
    for filename, values in packs.items():
        (OUT / filename).write_text(json.dumps(values, ensure_ascii=False, separators=(',', ':')) + '\n')
    manifest = dict(schema=1, source=SOURCE, sha256=hashlib.sha256(payload).hexdigest(),
        upstreamDate=(regex.search(rb'JMdict created: (\d{4}-\d{2}-\d{2})', xml).group(1).decode().strip()
            if regex.search(rb'JMdict created: (\d{4}-\d{2}-\d{2})', xml) else 'see upstream sha256'),
        license='CC-BY-SA-4.0', copyright='Electronic Dictionary Research and Development Group',
        modifications='Filtered noun/slang entries; kana spelling preferences; excluded restricted senses and obsolete/vulgar entries.',
        updateCommand='python3 Scripts/build_language_resources.py JMdict_e.gz',
        packs={k: dict(count=len(v), sha256=hashlib.sha256((OUT/k).read_bytes()).hexdigest()) for k,v in packs.items()})
    (OUT/'LanguageResourceSources.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(manifest['packs'], indent=2))


if __name__ == '__main__':
    build(Path(sys.argv[1]))
