import { describe, expect, test } from "bun:test";
import {
  failure,
  LineDecoder,
  RPC_ERROR,
  serializeMessage,
  success,
} from "./protocol.ts";

describe("LineDecoder", () => {
  test("buffers a split request and emits only complete nonempty lines", () => {
    const decoder = new LineDecoder();

    expect(decoder.push('{"jsonrpc":"2.0"')).toEqual([]);
    expect(decoder.push(',"id":1}\n\n{"id":2}\n')).toEqual([
      '{"jsonrpc":"2.0","id":1}',
      '{"id":2}',
    ]);
  });

  test("flush returns an unterminated final line once", () => {
    const decoder = new LineDecoder();
    decoder.push('{"id":1}');

    expect(decoder.flush()).toEqual(['{"id":1}']);
    expect(decoder.flush()).toEqual([]);
  });
});

describe("JSON-RPC envelopes", () => {
  test("constructs a success envelope without an error field", () => {
    expect(success(4, { protocol_version: 1 })).toEqual({
      jsonrpc: "2.0",
      id: 4,
      result: { protocol_version: 1 },
    });
  });

  test("constructs a stable unavailable error with recovery data", () => {
    expect(
      failure(7, RPC_ERROR.UNAVAILABLE, "tmux is unavailable", {
        recovery: "install_tmux",
      }),
    ).toEqual({
      jsonrpc: "2.0",
      id: 7,
      error: {
        code: -32002,
        message: "tmux is unavailable",
        data: { recovery: "install_tmux" },
      },
    });
  });

  test("serializes exactly one newline-delimited protocol message", () => {
    expect(serializeMessage(success("request-1", null))).toBe(
      '{"jsonrpc":"2.0","id":"request-1","result":null}\n',
    );
  });
});
