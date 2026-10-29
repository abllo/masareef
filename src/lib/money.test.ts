import { describe, expect, it } from 'vitest';
import { formatSAR, normalizeNumeric, parseAmount, percentages, sumHalalas, toInputValue } from './money';

describe('parseAmount', () => {
  it('converts riyals to halalas without float errors', () => {
    expect(parseAmount('0.1')).toBe(10);
    expect(parseAmount('0.29')).toBe(29); // 0.29 * 100 = 28.999… بالكسور العشرية
    expect(parseAmount('19.99')).toBe(1999);
    expect(parseAmount('1250')).toBe(125000);
    expect(parseAmount('12.')).toBe(1200);
  });

  it('accepts Arabic-Indic digits and separators', () => {
    expect(parseAmount('١٢٥٫٥')).toBe(12550);
    expect(parseAmount('١٬٢٠٠')).toBe(120000);
    expect(parseAmount('1,500.75')).toBe(150075);
    expect(normalizeNumeric('۳۴')).toBe('34');
  });

  it('rejects invalid or zero amounts', () => {
    for (const bad of ['', '0', '0.00', 'abc', '-5', '1.234', '1e3', '.']) {
      expect(parseAmount(bad)).toBeNull();
    }
  });
});

describe('toInputValue', () => {
  it('round-trips with parseAmount', () => {
    for (const h of [1, 10, 99, 100, 1205, 1250, 999999]) {
      expect(parseAmount(toInputValue(h))).toBe(h);
    }
    expect(toInputValue(1250)).toBe('12.5');
  });
});

describe('percentages', () => {
  it('always sums to exactly 100', () => {
    const p = percentages([1, 1, 1]);
    expect(p.reduce((a, b) => a + b, 0)).toBe(100);
    expect(percentages([3333, 3333, 3334]).reduce((a, b) => a + b, 0)).toBe(100);
  });
  it('handles empty totals', () => {
    expect(percentages([0, 0])).toEqual([0, 0]);
  });
});

describe('formatting', () => {
  it('formats SAR with Latin digits', () => {
    expect(formatSAR(125050)).toMatch(/1,?250\.5/);
    expect(sumHalalas([10, 20, 30])).toBe(60);
  });
});
