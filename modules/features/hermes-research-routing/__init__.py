"""Sends research subagents to Claude in two tiers and keeps every other subagent local.

Hermes' default delegation strategy gives every subagent the same model. This one adds a
`route` choice to each delegate_task task:
  local          the route the delegation section of config.yaml describes, which is the
                 parent's local model when that section is empty (the default)
  research       Claude's everyday research model
  deep-research  Claude's strongest model, only when the owner asks for a deep dive

Settings, under delegation.backends.research-routing:
  model:       the Claude model alias for research (default "sonnet")
  deep_model:  the Claude model alias for deep research (default "opus")
  provider:    the Claude provider's ID (default the subscription plugin's)
"""

from agent.delegation_provider import DelegationProvider

CLAUDE_PROVIDER = "claude-subscription-directsdk-experimental"
TIERS = {
    # route: (setting name, default model, label)
    "research": ("model", "sonnet", "Claude research"),
    "deep-research": ("deep_model", "opus", "Claude deep research"),
}

ROUTE_PARAMETER = {
    "type": "string",
    "enum": ["local", *TIERS],
    "description": (
        "Which model runs this subagent. 'research' is for research only: gathering and "
        "comparing information from many web sources, checking claims, or writing a sourced "
        "report. 'deep-research' uses a stronger, costlier model and is only for when the user "
        "explicitly asks for a deep dive or an in-depth, thorough investigation. Everything else, "
        "including coding, file work, system tasks and images, uses 'local'. Defaults to 'local'."
    ),
}

GUIDANCE = (
    "Set route='research' on a task only when it is research, and route='deep-research' only "
    "when the user asks for a deep dive. Give research tasks the web and browser toolsets. Both "
    "research routes use the owner's limited Claude subscription and send the task to Anthropic, "
    "so never send them private files, secrets or explicit content. If a research task fails, for "
    "example at a usage limit, tell the user and redo it with route='local'. When a research task "
    "finishes, file its report in the owner's wiki with the llm-wiki skill."
)


class ResearchRoutingProvider(DelegationProvider):
    @property
    def name(self) -> str:
        return "research-routing"

    @property
    def display_name(self) -> str:
        return "Research on Claude"

    @property
    def summary(self) -> str:
        return "Research subagents run on Claude, deep dives on its strongest model; every other subagent stays local."

    def task_parameters(self, config):
        return {"route": ROUTE_PARAMETER}

    def description(self, config):
        return GUIDANCE

    def route_task(self, task, config):
        tier = TIERS.get(task.get("route"))
        if tier is None:
            # The same route Hermes' default strategy takes.
            return {k: v for k, v in config.items() if k != "service_tier"}
        setting, default_model, label = tier
        settings = self.settings(config)
        return {
            "provider": str(settings.get("provider") or CLAUDE_PROVIDER),
            "model": str(settings.get(setting) or default_model),
            "label": label,
            # A failed Claude task is reported back, so the agent can redo it locally on purpose.
            "fallback_providers": [],
        }


def register(ctx) -> None:
    ctx.register_delegation_provider(ResearchRoutingProvider())
