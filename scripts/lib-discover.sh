#!/usr/bin/env bash
# Discovery of running club-3090 serving containers.
#
# Sourced by reconcile.sh and llmroute. Prints one TSV line per backend:
#
#   <container-name>\t<host-port>\t<model-name>\t<uptime>
#
# The detection chain mirrors club-3090/scripts/club3090-env.sh (read as a
# reference; that repo is never written to). The one deliberate difference:
# club3090-env.sh stops at the first container, we list them all, because the
# /b/<key>/ routes need every backend.

# Engine name prefixes. Union of the two lists in the club-3090 repo:
#   scripts/club3090-env.sh:46   and   scripts/gpu-mode.sh:1035
# This is what separates an engine from the companion services that come up
# with it (litellm, qdrant, openwebui, searxng, spark-dashboard).
#
# flash-next is not a club-3090 engine: it is built and run from ~/flash-next
# (containers `flash-next` and `flash-next-mtp`), so it is listed here by hand.
C3_ENGINE_RE='^(vllm-|llamacpp-|llama-cpp-|sglang-|beellama-|ik-llama-|flash-next(-|$))'

# model_from_endpoint <port> — ask the engine what it serves.
# Picks the longest id, matching club3090-env.sh's "most specific name" rule.
model_from_endpoint() {
	local port="$1" body ids
	body=$(curl -s --max-time 2 "http://127.0.0.1:${port}/v1/models" 2>/dev/null) || return 1
	[[ -z "$body" ]] && return 1

	ids=$(printf '%s' "$body" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
		| sed 's/.*"\([^"]*\)"$/\1/' | grep -v '^modelperm-')
	[[ -z "$ids" ]] && return 1

	# club3090-env.sh drops ids containing "inst"; keep that, but never let the
	# filter empty the list.
	local filtered
	filtered=$(printf '%s\n' "$ids" | grep -v 'inst')
	[[ -n "$filtered" ]] && ids="$filtered"

	printf '%s\n' "$ids" | awk '{ if (length($0) > length(best)) best = $0 } END { print best }'
}

# model_from_args <container> — read --served-model-name (vLLM/sglang) or
# --alias (llama.cpp/ik-llama) off the container command line. Used while the
# engine is still booting and /v1/models does not answer yet.
model_from_args() {
	local c="$1"
	docker inspect --format '{{range .Args}}{{println .}}{{end}}' "$c" 2>/dev/null \
		| grep -A1 -x -e '--served-model-name' -e '--alias' \
		| grep -v -x -e '--served-model-name' -e '--alias' -e '--' \
		| head -1
}

# port_from_args <container> — read --port off the container command line.
# Used for host-network engines, which publish nothing for `docker ps` to show.
port_from_args() {
	docker inspect --format '{{range .Args}}{{println .}}{{end}}' "$1" 2>/dev/null \
		| grep -A1 -x -e '--port' \
		| grep -x '[0-9]\+' \
		| head -1
}

# model_from_name <container> — last resort, same rewrites as club3090-env.sh.
model_from_name() {
	printf '%s' "$1" \
		| sed -E 's/^(vllm|llamacpp|llama-cpp|sglang|beellama|ik-llama)-//' \
		| sed -e 's/qwen36/qwen3.6/g' -e 's/qwen38/qwen3.8/g' -e 's/gemma4/gemma-4/g'
}

# discover — TSV of every running engine that publishes a host port, or that
# runs on the host network with an explicit --port.
discover() {
	local line name ports status port model
	# Ports goes last: tab is IFS whitespace, so an empty middle field would be
	# swallowed and shift Status into its place (host-network engines have none).
	while IFS=$'\t' read -r name status ports; do
		[[ -z "$name" ]] && continue
		[[ "$name" =~ $C3_ENGINE_RE ]] || continue

		port=$(printf '%s' "$ports" | sed -n 's/^[^:]*:\([0-9]\+\)->.*/\1/p' | head -1)
		[[ -z "$port" ]] && port=$(port_from_args "$name")
		[[ -z "$port" ]] && continue

		model=$(model_from_endpoint "$port")
		[[ -z "$model" ]] && model=$(model_from_args "$name")
		[[ -z "$model" ]] && model=$(model_from_name "$name")

		printf '%s\t%s\t%s\t%s\n' "$name" "$port" "$model" "${status#Up }"
	done < <(docker ps --filter status=running --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null)
}

# endpoint_ready <port> — does the engine answer yet?
endpoint_ready() {
	curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${1}/v1/models" 2>/dev/null
}

# select_active <preferred> <pinned> — rows of discover() on stdin.
#
# Prints "<via>\t<name>\t<port>\t<model>\t<uptime>" for the backend that should
# own :80, or nothing (exit 1) when the choice is not obvious. `via` is:
#
#   preferred  a standing preference matched a running backend
#   pinned     the last explicit pick is still running
#   sole       only one backend is up, so it elects itself
#
# The preference is checked first and deliberately never written to state/pinned:
# it has to survive periods where the preferred engine is down and another one
# auto-pins itself.
select_active() {
	local pref="$1" pin="$2" row n p m u via key
	local -a rows=()
	while IFS= read -r row; do [[ -n "$row" ]] && rows+=("$row"); done

	[[ ${#rows[@]} -eq 0 ]] && return 1

	for via in preferred pinned; do
		if [[ "$via" == preferred ]]; then key="$pref"; else key="$pin"; fi
		[[ -z "$key" ]] && continue
		for row in "${rows[@]}"; do
			IFS=$'\t' read -r n p m u <<<"$row"
			if [[ "$key" == "$n" || "$key" == "$p" ]]; then
				printf '%s\t%s\n' "$via" "$row"
				return 0
			fi
		done
	done

	if [[ ${#rows[@]} -eq 1 ]]; then
		printf 'sole\t%s\n' "${rows[0]}"
		return 0
	fi
	return 1
}

# read_state <file> — contents of a one-line state file, newlines stripped.
read_state() {
	local v=""
	[[ -f "$1" ]] && v=$(<"$1")
	printf '%s' "${v//$'\n'/}"
}
