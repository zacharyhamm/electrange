# Memory System Review

## Correctness findings

### 1. Recalled memories can reinforce themselves

Memories are injected into an assistant response, then that response is immediately passed back through memory extraction. Asking a question such as “Where do I work?” can therefore refresh an existing memory's timestamp and mention count even though the owner provided no new evidence. An assistant hallucination could also become a stored fact.

The practical fix is to classify extracted memories by source:

- `ownerFact`: a durable fact explicitly provided by the owner; it may create or refresh a memory.
- `exchangeOutcome`: a newly produced recommendation, research result, completed action, or decision; it may be stored as an episode but must not refresh an owner fact.
- `skip`: questions, requests, recalled answers, greetings, and other exchanges containing no new durable information.

During deduplication, an `exchangeOutcome` that matches an existing memory should be discarded rather than refreshing it. This preserves useful assistant-generated outcomes without creating the loop:

```text
recalled fact -> assistant repeats fact -> memory becomes newer
```

### 2. Merged memories retain stale embeddings and summaries

Deduplication appends new facts and entities but does not recompute the memory's embedding, summary, topic, or semantic-neighbor edges. Newly merged facts may therefore be missed by semantic queries. They are also absent from automatic prompt context because that context includes only the summary.

Recompute the embedding and semantic edges after a merge, and include relevant facts in the injected context block.

### 3. Corrections and contradictions remain simultaneously active

Statements such as “I work at X” followed later by “I now work at Y” generally create two current memories. There is no representation for correction, supersession, deletion, or forgetting, so retrieval may present both as true.

At minimum, give mutable owner facts a canonical key such as `owner/employer` and mark the previous value as superseded when a replacement is explicitly stated.

### 4. Extraction lacks conversational context

Memory extraction receives only the latest user/assistant exchange. References such as “she,” “there,” “that job,” or “the second option” may not resolve correctly.

Pass a small window of recent messages as context while requiring that new owner facts be supported by the newest owner message. Context may resolve references, but it must not count as new evidence.

### 5. Default construction can create divergent memory engines

`ChatBubbleWindowController` and `ChatToolRouter` can each create a separate `MemoryEngine`. Both initially load the same file, but their in-memory graphs do not observe one another's later changes. The explicit recall tool can consequently miss a memory that the controller just ingested.

`AppModel` currently shares one engine correctly. Make that shared dependency required so other callers cannot accidentally construct two live snapshots.

### 6. Keyword matching produces noisy false positives

Keyword retrieval uses substring matching. For example, `art` matches `party`, and common query words such as `what` or `remember` can qualify unrelated memories.

Match normalized whole tokens, remove duplicate query terms, and ignore a small set of common stopwords.

### 7. Persistence errors look like empty memory

Graph decoding and writing errors are silently discarded. A corrupt or incompatible graph loads as an empty graph and may later be overwritten, causing permanent memory loss.

Log persistence failures and retain the previous graph file when a load or replacement fails.

## Recommended implementation order

1. Prevent assistant repetition from refreshing owner facts.
2. Recompute merged embeddings and include facts in automatic context.
3. Add correction and supersession behavior for mutable owner facts.
4. Require one shared `MemoryEngine` instance.
5. Improve token matching and extraction context.
6. Measure recall before replacing the embedding model or expanding the graph design.

## Missing tests

- A recalled answer does not refresh an owner fact.
- A genuinely new assistant outcome is retained.
- A merged fact is reachable through semantic retrieval and automatic context.
- A correction supersedes the old value.
- Multi-turn references resolve without treating old context as new evidence.
- Controller ingestion is immediately visible to the recall tool.
- Corrupt or unwritable persistence does not silently erase the graph.
- Keyword matching uses complete tokens rather than substrings.

The existing test suite passed all 281 tests during the review.
