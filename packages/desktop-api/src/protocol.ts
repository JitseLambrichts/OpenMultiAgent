export type JsonRpcId = string | number | null;

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: JsonRpcId;
  method: string;
  params?: unknown;
}

export interface JsonRpcSuccess<Result = unknown> {
  jsonrpc: "2.0";
  id: JsonRpcId;
  result: Result;
}

export interface JsonRpcError {
  code: number;
  message: string;
  data?: unknown;
}

export interface JsonRpcFailure {
  jsonrpc: "2.0";
  id: JsonRpcId;
  error: JsonRpcError;
}

export interface JsonRpcNotification<Params = unknown> {
  jsonrpc: "2.0";
  method: string;
  params?: Params;
}

export type JsonRpcResponse<Result = unknown> =
  | JsonRpcSuccess<Result>
  | JsonRpcFailure;

export const RPC_ERROR = {
  PARSE_ERROR: -32700,
  INVALID_REQUEST: -32600,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32001,
  UNAVAILABLE: -32002,
  CONFLICT: -32003,
  NOT_FOUND: -32004,
  OPERATION_FAILED: -32005,
} as const;

export class LineDecoder {
  private buffer = "";

  push(chunk: string): string[] {
    this.buffer += chunk;
    const parts = this.buffer.split("\n");
    this.buffer = parts.pop() ?? "";
    return parts.map((line) => line.trim()).filter(Boolean);
  }

  flush(): string[] {
    const line = this.buffer.trim();
    this.buffer = "";
    return line ? [line] : [];
  }
}

export function success<Result>(
  id: JsonRpcId,
  result: Result,
): JsonRpcSuccess<Result> {
  return { jsonrpc: "2.0", id, result };
}

export function failure(
  id: JsonRpcId,
  code: number,
  message: string,
  data?: unknown,
): JsonRpcFailure {
  return {
    jsonrpc: "2.0",
    id,
    error: data === undefined ? { code, message } : { code, message, data },
  };
}

export function notification<Params>(
  method: string,
  params?: Params,
): JsonRpcNotification<Params> {
  return params === undefined
    ? { jsonrpc: "2.0", method }
    : { jsonrpc: "2.0", method, params };
}

export function serializeMessage(
  message: JsonRpcResponse | JsonRpcNotification,
): string {
  return `${JSON.stringify(message)}\n`;
}
