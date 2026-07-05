import { describe, it, expect } from 'vitest'
import { apiErrorMessage } from './apiClient'

describe('apiErrorMessage', () => {
  it('reads a plain {error} string', () => {
    expect(apiErrorMessage({ error: 'Nope' })).toBe('Nope')
  })

  it('flattens a changeset-style {errors: {field: [msgs]}}', () => {
    expect(
      apiErrorMessage({ errors: { email: ['is invalid', 'too short'] } })
    ).toBe('email: is invalid, too short')
  })

  it('joins multiple fields', () => {
    const msg = apiErrorMessage({ errors: { a: ['x'], b: ['y'] } })
    expect(msg).toContain('a: x')
    expect(msg).toContain('b: y')
  })

  it("returns null when there's nothing usable", () => {
    expect(apiErrorMessage(null)).toBeNull()
    expect(apiErrorMessage({})).toBeNull()
    expect(apiErrorMessage('boom')).toBeNull()
  })
})
