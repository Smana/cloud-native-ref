import { describe, expect, it } from 'vitest';
import { expandLink, parseLinks } from './links';

describe('parseLinks', () => {
  it('parses a JSON array of label/url pairs', () => {
    const got = parseLinks('[{"label":"Grafana","url":"https://g/{namespace}"}]');
    expect(got).toEqual([{ label: 'Grafana', url: 'https://g/{namespace}' }]);
  });

  it('returns nothing for absent, empty, malformed or wrongly-shaped input', () => {
    expect(parseLinks(undefined)).toEqual([]);
    expect(parseLinks('')).toEqual([]);
    expect(parseLinks('not json')).toEqual([]);
    expect(parseLinks('{"label":"x"}')).toEqual([]);
    expect(parseLinks('[{"label":"x"},{"url":"https://y"}]')).toEqual([]);
  });

  it('keeps only http(s) URLs', () => {
    expect(parseLinks('[{"label":"a","url":"javascript:alert(1)"},{"label":"b","url":"https://ok"}]')).toEqual([
      { label: 'b', url: 'https://ok' },
    ]);
  });
});

describe('expandLink', () => {
  const app = { namespace: 'demo', name: 'podinfo' };

  it('substitutes and encodes', () => {
    expect(expandLink('https://g/d/x?var-ns={namespace}&var-app={name}', app)).toBe(
      'https://g/d/x?var-ns=demo&var-app=podinfo',
    );
    expect(expandLink('https://g/{name}', { namespace: 'demo', name: 'a b' })).toBe('https://g/a%20b');
  });

  it('leaves unknown placeholders alone', () => {
    expect(expandLink('https://g/{cluster}/{name}', app)).toBe('https://g/{cluster}/podinfo');
  });
});
