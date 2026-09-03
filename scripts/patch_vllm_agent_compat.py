#!/usr/bin/env python3
"""Apply narrow GLM-5.3 compatibility fixes to the pinned vLLM runtime.

This derived image serves only GLM-5.3. The patch is intentionally strict:
- assistant content=None + tool_calls is normalized to an empty string;
- legacy enable_thinking/thinking chat kwargs are rejected instead of allowing
  known GLM-5.3 reasoning leakage.

The script fails closed if the pinned vLLM source shape is not recognized.
"""
from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path

NULL_MARKER = "GLM53_NULL_TOOL_CONTENT_PATCH"
THINK_MARKER = "GLM53_LEGACY_THINKING_GUARD"


def patch_chat_utils(text: str) -> str:
    if NULL_MARKER in text:
        return text
    needle = '''    for message in messages:\n        if message["role"] == "assistant" and "tool_calls" in message:\n'''
    replacement = f'''    for message in messages:\n        # {NULL_MARKER}: OpenAI agent clients commonly emit content=null.\n        if (\n            message.get("role") == "assistant"\n            and message.get("content") is None\n            and "tool_calls" in message\n        ):\n            message["content"] = ""\n\n        if message["role"] == "assistant" and "tool_calls" in message:\n'''
    if needle not in text:
        raise RuntimeError("Pinned vLLM chat_utils.py no longer matches expected source")
    return text.replace(needle, replacement, 1)


def patch_protocol(text: str) -> str:
    if THINK_MARKER in text:
        return text
    needle = "        user_kwargs = self.chat_template_kwargs or {}\n"
    replacement = f'''        user_kwargs = self.chat_template_kwargs or {{}}\n        # {THINK_MARKER}: GLM-5.3 ignores these legacy flags while the\n        # reasoning parser may stop extracting, which can leak scratchpad text.\n        legacy_thinking_flags = {{"enable_thinking", "thinking"}} & set(user_kwargs)\n        if legacy_thinking_flags:\n            raise VLLMValidationError(\n                "GLM-5.3 does not support chat_template_kwargs enable_thinking/thinking; "\n                "use reasoning_effort=low|high|max instead.",\n                parameter="chat_template_kwargs",\n            )\n'''
    if needle not in text:
        raise RuntimeError("Pinned vLLM protocol no longer matches expected source")
    return text.replace(needle, replacement, 1)


def module_path(module: str) -> Path:
    spec = importlib.util.find_spec(module)
    if spec is None or spec.origin is None:
        raise RuntimeError(f"Could not locate installed module: {module}")
    return Path(spec.origin)


def apply_file(path: Path, patcher) -> None:
    original = path.read_text(encoding="utf-8")
    patched = patcher(original)
    if patched != original:
        path.write_text(patched, encoding="utf-8")
        print(f"Patched {path}")
    else:
        print(f"Already patched {path}")


def self_test() -> None:
    chat_sample = '''def _postprocess_messages(messages):\n    for message in messages:\n        if message["role"] == "assistant" and "tool_calls" in message:\n            pass\n'''
    patched = patch_chat_utils(chat_sample)
    assert NULL_MARKER in patched
    assert 'message["content"] = ""' in patched
    assert patch_chat_utils(patched) == patched

    protocol_sample = '''    def f(self):\n        user_kwargs = self.chat_template_kwargs or {}\n        return user_kwargs\n'''
    guarded = patch_protocol(protocol_sample)
    assert THINK_MARKER in guarded
    assert "legacy_thinking_flags" in guarded
    assert patch_protocol(guarded) == guarded
    print("patch_vllm_agent_compat self-test OK")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return

    apply_file(module_path("vllm.entrypoints.chat_utils"), patch_chat_utils)
    apply_file(
        module_path("vllm.entrypoints.openai.chat_completion.protocol"),
        patch_protocol,
    )
    apply_file(
        module_path("vllm.entrypoints.openai.responses.protocol"),
        patch_protocol,
    )

    # Verify the installed files in a fresh read, not only in-memory strings.
    chat_text = module_path("vllm.entrypoints.chat_utils").read_text(encoding="utf-8")
    chat_protocol = module_path(
        "vllm.entrypoints.openai.chat_completion.protocol"
    ).read_text(encoding="utf-8")
    responses_protocol = module_path(
        "vllm.entrypoints.openai.responses.protocol"
    ).read_text(encoding="utf-8")
    if NULL_MARKER not in chat_text:
        raise RuntimeError("content=null normalization patch verification failed")
    if THINK_MARKER not in chat_protocol or THINK_MARKER not in responses_protocol:
        raise RuntimeError("legacy thinking guard verification failed")
    print("GLM-5.3 vLLM compatibility patches verified")


if __name__ == "__main__":
    main()
