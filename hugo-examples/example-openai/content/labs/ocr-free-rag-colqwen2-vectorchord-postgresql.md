---
title: "Beyond Text: Building an OCR-Free RAG System in PostgreSQL with ColQwen2, VectorChord, and Modal"
description: "Build a visually-aware, OCR-free document RAG pipeline in PostgreSQL using ColQwen2 multi-vector embeddings, VectorChord MaxSim search, and Modal GPU processing."
author: "vectorchord"
date: 2026-04-27
heroImage: /images/covers/ocr-free-rag-colqwen2-vectorchord-postgresql.svg
---

Building effective Retrieval-Augmented Generation (RAG) systems for documents often feels like wrestling with messy, complex pipelines. Especially when dealing with PDFs or scanned images, traditional methods rely heavily on Optical Character Recognition (OCR) and layout analysis. These steps can be slow, error-prone, and often lose crucial visual context like tables, figures, and formatting.

**But what if you could query documents based on _how they look_, not just the extracted text?**

This post is your guide to building exactly that: an **OCR-free RAG system** directly within your familiar PostgreSQL database. We'll leverage the power of the **ColQwen2** Vision Language Model, the efficiency of **VectorChord** for multi-vector search in Postgres, and the scalability of **Modal** for GPU-powered embedding generation. Get ready to simplify your RAG stack and potentially boost your retrieval accuracy, all without complex pre-processing.

We'll cover:

- What ColQwen2 is and why it's a game-changer.
- How VectorChord makes advanced vector search possible in Postgres.
- A step-by-step tutorial to build and evaluate the system.

## What is ColQwen2? The Power of Visual Understanding

To grasp ColQwen2, let's first look at its foundation: **ColPali**. As introduced in the paper [**ColPali: Efficient Document Retrieval with Vision Language Models**](https://arxiv.org/abs/2407.01449), ColPali represents a novel approach using Vision Language Models (VLMs). Instead of relying on imperfect OCR, it directly indexes documents using their rich **visual features** - text, images, tables, layout, everything the eye can see.

Think about the limitations of traditional OCR: complex layouts get mangled, tables become gibberish, and images are often ignored entirely. It's like trying to understand a book by only reading a flawed transcript. ColPali avoids this by using a powerful VLM (originally PaliGemma) to create embeddings that capture the document's holistic visual nature. Two key concepts make it shine:

1. **Contextualized Vision Embeddings:** Generating rich embeddings directly from the document image using a VLM.
2. **Late Interaction:** This clever technique allows the query's textual meaning to directly interact with the document's detailed visual features at search time. It's not just matching text summaries; it's comparing the query concept against the visual evidence within the document page.

![The ColPali architecture (Image from the ColPali paper)](https://cdn-uploads.huggingface.co/production/uploads/60f2e021adf471cbdf8bb660/La8vRJ_dtobqs6WQGKTzB.png)

**ColQwen2** builds upon this powerful ColPali architecture but swaps the underlying VLM for the more recent **Qwen2-VL-2B**. It generates [**ColBERT**-style](https://arxiv.org/abs/2004.12832) multi-vector representations, capturing fine-grained details from both text and images. As seen on the [**vidore-leaderboard**](https://huggingface.co/spaces/vidore/vidore-leaderboard), ColQwen2 delivers impressive performance with practical model size.

## How Does VectorChord Enable ColQwen2 in Postgres?

This is where **VectorChord** becomes the crucial piece of the puzzle, bringing this cutting-edge VLM capability into your PostgreSQL database. ColQwen2 (and ColPali) relies heavily on those **multi-vector representations** and the **Late Interaction** mechanism, specifically requiring an efficient **MaxSim (Maximum Similarity)** operation.

Calculating MaxSim - finding the highest similarity score between any vector in the query set and any vector in the document set - can be computationally brutal, especially across millions of document vectors. VectorChord tackles this head-on:

- **Native Multi-Vector Support:** It's designed from the ground up to handle multi-vector data efficiently within Postgres.
- **Optimized MaxSim:** Drawing inspiration from the [**WARP paper**](https://arxiv.org/abs/2501.17788), VectorChord uses techniques like dynamic similarity imputation to dramatically speed up MaxSim calculations, making large-scale visual document retrieval feasible.
- **Hybrid Search Ready:** Beyond multi-vector, it also supports dense, sparse, and hybrid search (check out our [**previous post**](https://blog.vectorchord.ai/hybrid-search-with-postgres-native-bm25-and-vectorchord)).
- **Scalable and Disk-Friendly:** Designed for performance without demanding excessive resources.

In short, VectorChord transforms PostgreSQL into a powerhouse capable of handling the advanced vector search techniques required by models like ColQwen2 or ColPali.

## Tutorial: Building Your OCR-Free RAG System

Alright, theory's great, but let's roll up our sleeves and build this thing. We'll walk through setting up the environment, processing data using Modal for scalable embedding generation, indexing into VectorChord within Postgres, and finally evaluating our shiny new OCR-free RAG system.

### Prerequisites

Before we start, ensure you have:

- A PostgreSQL instance (Docker recommended) with the VectorChord extension installed or a [**VectorChord Cloud**](https://cloud.vectorchord.ai/) cluster.
- A [**Modal**](https://modal.com/) account (free tier available). Modal's fast GPU provisioning and scaling are perfect for embedding generation. To process a large volume of documents efficiently with ColQwen2, Modal's rapid startup and GPU autoscaling significantly reduce runtime versus local-only processing.

If you want to reproduce the tutorial quickly, you can use the `tensorchord/vchord-suite` image to run multiple extensions that TensorChord provides.

Run the following command to start Postgres with VectorChord-BM25 and VectorChord:

```bash
docker run \
  --name vchord-suite \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  -d tensorchord/vchord-suite:pg17-latest
```

```sql
CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
CREATE EXTENSION IF NOT EXISTS pg_tokenizer CASCADE;
CREATE EXTENSION IF NOT EXISTS vchord_bm25 CASCADE;
\dx
pg_tokenizer | 0.1.0   | tokenizer_catalog | pg_tokenizer
vchord       | 0.3.0   | public            | vchord: Vector database plugin for Postgres, written in Rust, specifically designed for LLM
vchord_bm25  | 0.2.0   | bm25_catalog      | vchord_bm25: A postgresql extension for bm25 ranking algorithm
vector       | 0.8.0   | public            | vector data type and ivfflat and hnsw access methods
```

Set up Modal:

```bash
pip install modal
python3 -m modal setup
```

### Step 1: Load the Data (Using Modal Volumes)

We'll use the [**ViDoRe Benchmark**](https://huggingface.co/collections/vidore/vidore-benchmark-667173f98e70a1c0fa4db00d) dataset. To handle this data efficiently across distributed Modal functions, we'll download it to a [**Modal Volume**](https://modal.com/docs/guide/volumes). Volumes provide persistent shared storage ideal for this "download once, process many times" flow.

```python
image = modal.Image.debian_slim().pip_install("datasets", "huggingface_hub", "Pillow")
DATASET_DIR = "/data"
DATASET_VOLUME = modal.Volume.from_name("colpali-dataset", create_if_missing=True)
app = modal.App(image=image)

@app.function(volumes={DATASET_DIR: DATASET_VOLUME}, timeout=3000)
def download_dataset(cache=False) -> None:
    from datasets import load_dataset
    from tqdm import tqdm

    collection_dataset_names = get_collection_dataset_names("vidore/vidore-benchmark-667173f98e70a1c0fa4db00d")
    for dataset_name in tqdm(collection_dataset_names, desc="vidore benchmark dataset(s)"):
        dataset = load_dataset(dataset_name, split="test", num_proc=10)
        unique_indices = dataset.to_pandas().drop_duplicates(subset="image_filename", keep="first").index
        dataset = dataset.select(unique_indices)
        dataset.save_to_disk(f"{DATASET_DIR}/{dataset_name}")
```

Modal offers a straightforward Python API. With `modal.Image`, you define the base image for your app, and with the `@app.function` decorator you define cloud-executed tasks.

Run the download function:

```bash
modal run dataset.py::download_dataset
```

### Step 2: Process Data and Generate Embeddings (With Modal and ColQwen2)

This is the heavy lifting: converting document images into ColQwen2 multi-vector embeddings. Doing this locally at scale can be slow. Modal helps with:

- **Easy GPU Access and Autoscaling:** Launch ColQwen2 embedding workers on demand.
- **Recovery:** Checkpoint progress in a separate Modal Volume so interrupted runs can resume.

```python
# embedding.py (illustrative)
modal_app = modal.App()

@modal_app.function(...)
def embed_dataset(down_scale: float = 1.0, batch_size: int = BATCH_SIZE):
    colpali_server = ColPaliServer()
    # load dataset shards, read checkpoints, call remote embedding methods
    print("Embedding generation complete.")

# server.py (illustrative)
@modal_app.cls(gpu=GPU_CONFIG, ...)
class ColPaliServer:
    @modal.enter()
    def load_model_and_start_server(self):
        self.client = httpx.AsyncClient(...)

    @modal.exit()
    def shutdown_server(self):
        pass

    @modal.method()
    async def embed_images(self, images: List[str]) -> np.ndarray:
        return embeddings_numpy_array

# colpali.py
class ColPaliModel:
    def __init__(self, model_name: str = "vidore/colqwen2-v1.0", cache_dir: str = "/model"):
        if self.model_name == "vidore/colqwen2-v1.0":
            from colpali_engine.models import ColQwen2, ColQwen2Processor
            from transformers.utils.import_utils import is_flash_attn_2_available

            model = ColQwen2.from_pretrained(
                self.model_name,
                torch_dtype=torch.bfloat16,
                device_map="cuda:0",
                attn_implementation="flash_attention_2" if is_flash_attn_2_available() else None,
                cache_dir=self.cache_dir,
            ).eval()

            colpali_processor = ColQwen2Processor.from_pretrained(
                self.model_name,
                cache_dir=self.cache_dir,
            )
```

Generate embeddings:

```bash
modal run embedding.py::embed_dataset
```

### Step 3: Create Index in VectorChord (Using vechord SDK)

With embeddings generated in Modal, download them locally:

```bash
modal volume get colpali-embedding-checkpoint /path/to/local/vidore_embeddings
```

Then use the **vechord** SDK to load embeddings into PostgreSQL and create multi-vector indexes.

- GitHub: [https://github.com/tensorchord/vechord](https://github.com/tensorchord/vechord)

```python
MultiVector = List[Vector[128]]

lists = 2500

class Image(Table, kw_only=True):
    uid: Optional[PrimaryKeyAutoIncrease] = None
    image_embedding: Annotated[MultiVector, MultiVectorIndex(lists=lists)]
    query_embedding: Annotated[MultiVector, MultiVectorIndex(lists=lists)]
    query: str = None
    dataset: Optional[str] = None
    dataset_id: Optional[int] = None

DB_URL = "postgresql://postgres:postgres@127.0.0.1:5432/postgres"
vr = VechordRegistry("colpali", DB_URL)
vr.register([Image])

@vr.inject(output=Image)
def load_image_embeddings(path: str) -> Iterator[Image]:
    print(f"Loaded embeddings from {path}")

if __name__ == "__main__":
    embedding_dir = "/path/to/local/vidore_embeddings"
    load_image_embeddings(embedding_dir)
    print("Data loaded and indexed into VectorChord.")
```

### Step 4: Evaluation - Does It Work?

Now evaluate retrieval quality and speed using NDCG@10 and Recall@10, and compare with and without VectorChord's **WARP** optimization.

In this tutorial, we use [vidore/arxivqa_test_subsampled](https://huggingface.co/datasets/vidore/arxivqa_test_subsampled) for evaluation queries.

![Evaluation sample rows](https://cdn.hashnode.com/res/hashnode/image/upload/v1743483589729/4bc711ae-666c-4bf8-ac3c-63be23ce3071.png)

```python
TOP_K = 10

class Evaluation(msgspec.Struct):
    map: float
    ndcg: float
    recall: float

def evaluate(queries: list[Image], probes: int, max_maxsim_tuples: int) -> list[Evaluation]:
    result = []
    for query in queries:
        vector = query.query_embedding
        docs: list[Image] = vr.search_by_multivec(
            Image, vector, topk=TOP_K, probe=probes, max_maxsim_tuples=max_maxsim_tuples
        )
        score = BaseEvaluator.evaluate_one(query.uid, [doc.uid for doc in docs])
        result.append(
            Evaluation(
                map=score.get("map"),
                ndcg=score.get("ndcg"),
                recall=score.get(f"recall_{TOP_K}"),
            )
        )
    return result
```

Example results:

```text
# Disable WARP
ndcg@10 0.8615
recall@10 0.92
Total execution time: 810 seconds

# Enable WARP
ndcg@10 0.8353
recall@10 0.90
Total execution time: 41 seconds
```

**Analysis:**

- **High Baseline Accuracy:** Without WARP, NDCG@10 reaches **0.8615** and Recall@10 reaches **0.92**, showing strong visual retrieval effectiveness.
- **Dramatic WARP Speed Boost:** Enabling WARP reduces total time from 810 seconds to **41 seconds**, about **18.7x faster**.
- **Minimal Accuracy Trade-off:** The speedup comes with only a small drop (NDCG@10: 0.8615 -> 0.8353, Recall@10: 0.92 -> 0.90).

## Conclusion: Visual RAG Made Simpler in Postgres

In this tutorial, we built a high-performance, **OCR-free RAG system** by combining the visual understanding of **ColQwen2**, the scalable multi-vector search of **VectorChord** in **PostgreSQL**, and the GPU scaling of **Modal**. This stack lets you query documents by visual content directly, without brittle OCR pipelines.

That opens practical opportunities for visually rich domains such as scientific papers, invoices, product manuals, and historical archives.

Ready to try it?

- **Explore the code:** [https://github.com/xieydd/vectorchord-colqwen2](https://github.com/xieydd/vectorchord-colqwen2)
- **Read VectorChord docs:** [https://docs.vectorchord.ai/](https://docs.vectorchord.ai/)
- **Try VectorChord Cloud:** [https://cloud.vectorchord.ai/](https://cloud.vectorchord.ai/)
- **Experiment further:** Try different VLMs and datasets.

This approach is a meaningful step toward simpler, more robust, and visually aware document retrieval systems.

## References

- [https://huggingface.co/vidore/colqwen2-v1.0](https://huggingface.co/vidore/colqwen2-v1.0)
- [https://huggingface.co/blog/manu/colpali](https://huggingface.co/blog/manu/colpali)
- [https://blog.vespa.ai/scaling-colpali-to-billions/](https://blog.vespa.ai/scaling-colpali-to-billions/)
