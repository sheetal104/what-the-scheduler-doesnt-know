#!/usr/bin/env python3
"""OpenAI-compatible load gen: fixed prompt tokens, streaming TTFT, decode-heavy E2E."""

import argparse
import asyncio
import json
import os
import time
from pathlib import Path

try:
    import aiohttp
except ImportError:
    raise SystemExit("pip install aiohttp")

PROMPT_CACHE: str | None = None


def build_prompt(model_path: str, target_tokens: int) -> str:
    global PROMPT_CACHE
    if PROMPT_CACHE is not None:
        return PROMPT_CACHE
    seed = (
        "You are a helpful assistant. Explain how Linux CPU scheduling, NUMA locality, "
        "and GPU kernel launch interact during large-language-model inference. "
        "Cover prefill versus decode, batching, KV cache growth, and why cluster-level "
        "metrics can look healthy while tail latency degrades. "
    )
    try:
        from transformers import AutoTokenizer

        tok = AutoTokenizer.from_pretrained(model_path, trust_remote_code=True)
        ids = tok.encode(seed, add_special_tokens=False)
        unit = ids if ids else tok.encode("hello ", add_special_tokens=False)
        while len(ids) < target_tokens:
            ids.extend(unit)
        ids = ids[:target_tokens]
        PROMPT_CACHE = tok.decode(ids)
        return PROMPT_CACHE
    except Exception:
        # Fallback: approximate length when tokenizer unavailable offline.
        text = seed
        while len(text.split()) < target_tokens:
            text += seed
        PROMPT_CACHE = " ".join(text.split()[:target_tokens])
        return PROMPT_CACHE


async def one_request(
    session: aiohttp.ClientSession,
    url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    sem: asyncio.Semaphore,
) -> dict:
    payload = {
        "model": model,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "stream": True,
        "temperature": 0,
        "seed": 42,
    }
    t0 = time.perf_counter()
    ttft = None
    chunks = 0
    async with sem:
        async with session.post(url, json=payload) as resp:
            resp.raise_for_status()
            async for line in resp.content:
                if not line:
                    continue
                s = line.decode("utf-8", errors="ignore").strip()
                if not s.startswith("data:"):
                    continue
                data = s[5:].strip()
                if data == "[DONE]":
                    break
                chunks += 1
                if ttft is None:
                    ttft = (time.perf_counter() - t0) * 1000
    e2e = (time.perf_counter() - t0) * 1000
    decode_ms = max(0.0, e2e - (ttft or 0.0))
    tpot_ms = decode_ms / max(chunks - 1, 1) if chunks > 1 else None
    return {
        "ts": time.time(),
        "ttft_ms": ttft if ttft is not None else e2e,
        "e2e_ms": e2e,
        "decode_ms": decode_ms,
        "tpot_ms": tpot_ms,
        "stream_chunks": chunks,
    }


async def run_phase(
    session: aiohttp.ClientSession,
    url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    concurrency: int,
    n_requests: int | None,
    duration: float | None,
    out: Path | None,
) -> int:
    sem = asyncio.Semaphore(concurrency)
    tasks: set[asyncio.Task] = set()
    end = time.time() + duration if duration else None
    n = 0
    fh = out.open("w") if out else None
    try:
        while True:
            if n_requests is not None and n >= n_requests:
                if not tasks:
                    break
            elif end is not None and time.time() >= end and not tasks:
                break
            while len(tasks) < concurrency:
                if n_requests is not None and n + len(tasks) >= n_requests:
                    break
                if end is not None and time.time() >= end:
                    break
                tasks.add(
                    asyncio.create_task(
                        one_request(session, url, model, prompt, max_tokens, sem)
                    )
                )
            if not tasks:
                break
            done, tasks = await asyncio.wait(
                tasks, timeout=0.05, return_when=asyncio.FIRST_COMPLETED
            )
            for t in done:
                row = await t
                if fh:
                    fh.write(json.dumps(row) + "\n")
                    fh.flush()
                n += 1
    finally:
        if fh:
            fh.close()
    return n


async def main_async(args: argparse.Namespace) -> None:
    prompt = build_prompt(args.model_path, args.prompt_tokens)
    timeout = aiohttp.ClientTimeout(total=max(600, args.duration + 120))
    async with aiohttp.ClientSession(timeout=timeout) as session:
        print(f"warmup {args.warmup} requests...", flush=True)
        await run_phase(
            session,
            args.url,
            args.model,
            prompt,
            args.max_tokens,
            args.concurrency,
            n_requests=args.warmup,
            duration=None,
            out=None,
        )
        print(
            f"measure concurrency={args.concurrency} duration={args.duration}s",
            flush=True,
        )
        args.out.parent.mkdir(parents=True, exist_ok=True)
        n = await run_phase(
            session,
            args.url,
            args.model,
            prompt,
            args.max_tokens,
            args.concurrency,
            n_requests=None,
            duration=args.duration,
            out=args.out,
        )
    print(f"wrote {n} rows to {args.out}")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="http://127.0.0.1:8000/v1/completions")
    p.add_argument("--model", default=os.environ.get("MODEL", ""))
    p.add_argument(
        "--model-path",
        default=os.environ.get("LOCAL_MODEL_DIR", os.environ.get("MODEL", "")),
    )
    p.add_argument("--prompt-tokens", type=int, default=512)
    p.add_argument("--max-tokens", type=int, default=128)
    p.add_argument("--warmup", type=int, default=40)
    p.add_argument("--duration", type=float, default=300)
    p.add_argument("--concurrency", type=int, default=16)
    p.add_argument("--out", type=Path, default=Path("/tmp/kubecon_experiments/bench.jsonl"))
    args = p.parse_args()
    if not args.model:
        args.model = args.model_path
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
