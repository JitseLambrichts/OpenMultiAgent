import { isAgentName } from "@oma/core";
import {
  failure,
  type JsonRpcRequest,
  type JsonRpcResponse,
  RPC_ERROR,
  success,
} from "./protocol.ts";
import { DesktopError, type DesktopServices } from "./services.ts";

type Params = Record<string, unknown>;

function objectParams(value: unknown): Params {
  if (value === undefined) return {};
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DesktopError(
      RPC_ERROR.INVALID_PARAMS,
      "params must be an object",
    );
  }
  return value as Params;
}

function requiredString(params: Params, name: string): string {
  const value = params[name];
  if (typeof value !== "string" || value.trim() === "") {
    throw new DesktopError(
      RPC_ERROR.INVALID_PARAMS,
      `${name} must be a non-empty string`,
    );
  }
  return value;
}

function optionalString(params: Params, name: string): string | undefined {
  const value = params[name];
  if (value === undefined) return undefined;
  if (typeof value !== "string") {
    throw new DesktopError(
      RPC_ERROR.INVALID_PARAMS,
      `${name} must be a string`,
    );
  }
  return value;
}

function optionalBoolean(params: Params, name: string): boolean | undefined {
  const value = params[name];
  if (value === undefined) return undefined;
  if (typeof value !== "boolean") {
    throw new DesktopError(
      RPC_ERROR.INVALID_PARAMS,
      `${name} must be a boolean`,
    );
  }
  return value;
}

function optionalInteger(params: Params, name: string): number | undefined {
  const value = params[name];
  if (value === undefined) return undefined;
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new DesktopError(
      RPC_ERROR.INVALID_PARAMS,
      `${name} must be an integer`,
    );
  }
  return value;
}

function optionalStringArray(
  params: Params,
  name: string,
): string[] | undefined {
  const value = params[name];
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || value.some((v) => typeof v !== "string")) {
    throw new DesktopError(
      RPC_ERROR.INVALID_PARAMS,
      `${name} must be a string array`,
    );
  }
  return value as string[];
}

function requiredAgent(params: Params) {
  const agent = requiredString(params, "agent");
  if (!isAgentName(agent)) {
    throw new DesktopError(
      RPC_ERROR.INVALID_PARAMS,
      "agent must be a valid slug (a-z, 0-9, -, _)",
    );
  }
  return agent;
}

async function invoke(
  services: DesktopServices,
  method: string,
  rawParams: unknown,
): Promise<unknown> {
  const params = objectParams(rawParams);
  switch (method) {
    case "system.hello":
      return services.hello();
    case "system.health":
      return services.health();
    case "system.shutdown":
      return services.shutdown();
    case "project.list":
      return services.projectList();
    case "project.add":
      return services.projectAdd({
        repo_path: requiredString(params, "repo_path"),
        display_name: optionalString(params, "display_name"),
      });
    case "project.detail":
      return services.projectDetail({
        project_id: requiredString(params, "project_id"),
      });
    case "project.remove":
      return services.projectRemove({
        project_id: requiredString(params, "project_id"),
      });
    case "session.list": {
      const status = optionalString(params, "status");
      if (status !== undefined && status !== "active" && status !== "ended") {
        throw new DesktopError(
          RPC_ERROR.INVALID_PARAMS,
          "status must be active or ended",
        );
      }
      return services.sessionList({
        repo_path: optionalString(params, "repo_path"),
        status,
      });
    }
    case "session.status":
      return services.sessionStatus({
        session_id: requiredString(params, "session_id"),
      });
    case "session.create":
      return services.sessionCreate({
        repo_path: requiredString(params, "repo_path"),
        agent: requiredAgent(params),
        worktree: optionalBoolean(params, "worktree"),
        branch: optionalString(params, "branch"),
        title: optionalString(params, "title"),
        prompt: optionalString(params, "prompt"),
      });
    case "session.resume":
      return services.sessionResume({
        session_id: requiredString(params, "session_id"),
      });
    case "session.switch":
      return services.sessionSwitch({
        session_id: requiredString(params, "session_id"),
        agent: requiredAgent(params),
        prompt: optionalString(params, "prompt"),
      });
    case "session.end":
      return services.sessionEnd({
        session_id: requiredString(params, "session_id"),
      });
    case "session.remove":
      return services.sessionRemove({
        session_id: requiredString(params, "session_id"),
        force: optionalBoolean(params, "force"),
        keep_worktree: optionalBoolean(params, "keep_worktree"),
      });
    case "transcript.list":
      return services.transcriptList({
        session_id: requiredString(params, "session_id"),
        before: optionalString(params, "before"),
        limit: optionalInteger(params, "limit"),
      });
    case "memory.list":
      return services.memoryList({
        repo_path: optionalString(params, "repo_path"),
        limit: optionalInteger(params, "limit"),
      });
    case "memory.search":
      return services.memorySearch({
        query: requiredString(params, "query"),
        repo_path: optionalString(params, "repo_path"),
        limit: optionalInteger(params, "limit"),
      });
    case "docs.list":
      return services.docsList({
        repo_path: requiredString(params, "repo_path"),
      });
    case "promotion.extract":
      return services.promotionExtract({
        session_id: requiredString(params, "session_id"),
      });
    case "promotion.auto_check":
      return services.promotionAutoCheck({
        session_id: requiredString(params, "session_id"),
      });
    case "promotion.pending_count":
      return services.promotionPendingCount();
    case "promotion.preview":
      return services.promotionPreview({
        session_id: requiredString(params, "session_id"),
      });
    case "promotion.apply":
      return services.promotionApply({
        session_id: requiredString(params, "session_id"),
      });
    case "terminal.attachment":
      return services.terminalAttachment({
        session_id: requiredString(params, "session_id"),
      });
    case "agent.list":
      return services.customAgentList();
    case "agent.add":
      return services.customAgentAdd({
        id: optionalString(params, "id"),
        name: optionalString(params, "name"),
        binary: optionalString(params, "binary"),
        launchArgs: optionalStringArray(params, "launch_args"),
        symbol: optionalString(params, "symbol"),
      });
    case "agent.update":
      return services.customAgentUpdate({
        id: requiredString(params, "id"),
        name: optionalString(params, "name"),
        binary: optionalString(params, "binary"),
        launchArgs: optionalStringArray(params, "launch_args"),
        symbol: optionalString(params, "symbol"),
      });
    case "agent.remove":
      return services.customAgentRemove({
        id: requiredString(params, "id"),
      });
    case "agent.system_prompt.list":
      return services.agentSystemPromptList();
    case "agent.system_prompt.get":
      return services.agentSystemPromptGet({
        agent: requiredString(params, "agent"),
      });
    case "agent.system_prompt.set": {
      const systemPrompt = params["system_prompt"];
      if (systemPrompt !== undefined && typeof systemPrompt !== "string") {
        throw new DesktopError(
          RPC_ERROR.INVALID_PARAMS,
          "system_prompt must be a string",
        );
      }
      return services.agentSystemPromptSet({
        agent: requiredString(params, "agent"),
        system_prompt:
          typeof systemPrompt === "string" ? systemPrompt : undefined,
      });
    }
    default:
      throw new DesktopError(
        RPC_ERROR.METHOD_NOT_FOUND,
        `Method not found: ${method}`,
      );
  }
}

export function createRouter(services: DesktopServices) {
  return {
    async dispatch(request: JsonRpcRequest): Promise<JsonRpcResponse | null> {
      const notification = request.id === undefined;
      try {
        const result = await invoke(services, request.method, request.params);
        return notification ? null : success(request.id ?? null, result);
      } catch (error) {
        if (notification) return null;
        if (error instanceof DesktopError) {
          return failure(
            request.id ?? null,
            error.code,
            error.message,
            error.data,
          );
        }
        return failure(
          request.id ?? null,
          RPC_ERROR.OPERATION_FAILED,
          "Operation failed",
          { detail: error instanceof Error ? error.message : String(error) },
        );
      }
    },
  };
}
