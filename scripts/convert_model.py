#!/usr/bin/env python3
"""Convert all-MiniLM-L6-v2 to CoreML format for Textream.

Requires Python 3.12 (coremltools native extensions aren't available for 3.14).

Usage:
    python3.12 -m venv .venv
    .venv/bin/pip install coremltools==9.0 'numpy<2' torch transformers
    .venv/bin/python scripts/convert_model.py

Outputs:
    Textream/Textream/MiniLM.mlpackage/  (43 MB, gitignored)
    Textream/Textream/vocab.txt          (30522 tokens)
"""

import shutil

import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer, BertConfig

MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
MAX_SEQ_LENGTH = 128  # sufficient for teleprompter segments

print("Loading model and tokenizer...")
tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)

# Load with eager attention to avoid SDPA tracing issues
config = BertConfig.from_pretrained(MODEL_NAME)
config.attn_implementation = "eager"
model = AutoModel.from_pretrained(MODEL_NAME, config=config)
model.eval()


class TracedModel(torch.nn.Module):
    """Wrapper for tracing that handles attention mask conversion internally.

    BERT's attention mask processing uses ops like `new_ones` that CoreML
    can't convert. We pre-compute the extended attention mask here so the
    traced graph only contains supported ops.
    """

    def __init__(self, model):
        super().__init__()
        self.embeddings = model.embeddings
        self.encoder = model.encoder

    def forward(self, input_ids, attention_mask):
        input_ids = input_ids.long()
        attention_mask = attention_mask.long()

        # Get embeddings
        embedding_output = self.embeddings(input_ids=input_ids)

        # Pre-compute extended attention mask (what BertModel.forward does internally)
        # Shape: [batch, 1, 1, seq_len] with 0.0 for attend, -10000.0 for mask
        extended_attention_mask = attention_mask.unsqueeze(1).unsqueeze(2).to(
            dtype=embedding_output.dtype
        )
        extended_attention_mask = (1.0 - extended_attention_mask) * -10000.0

        # Run encoder directly with pre-computed mask
        encoder_output = self.encoder(
            embedding_output,
            attention_mask=extended_attention_mask,
        )
        return encoder_output.last_hidden_state


wrapper = TracedModel(model)
wrapper.eval()

# Trace with dummy input
dummy_input_ids = torch.zeros(1, MAX_SEQ_LENGTH, dtype=torch.int32)
dummy_attention_mask = torch.ones(1, MAX_SEQ_LENGTH, dtype=torch.int32)

print("Tracing model with torch.jit.trace...")
with torch.no_grad():
    traced = torch.jit.trace(wrapper, (dummy_input_ids, dummy_attention_mask))

print("Converting to CoreML...")
mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, MAX_SEQ_LENGTH), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, MAX_SEQ_LENGTH), dtype=np.int32),
    ],
    outputs=[ct.TensorType(name="last_hidden_state")],
    compute_units=ct.ComputeUnit.ALL,
    minimum_deployment_target=ct.target.macOS13,
)

output_path = "Textream/Textream/MiniLM.mlpackage"
mlmodel.save(output_path)
print(f"Saved CoreML model to {output_path}")

# Copy vocab.txt
vocab_file = tokenizer.vocab_file
shutil.copy(vocab_file, "Textream/Textream/vocab.txt")
print(f"Copied vocab.txt from {vocab_file}")

print("\nDone! Next steps:")
print("  1. Add MiniLM.mlpackage and vocab.txt to the Xcode project target")
print("  2. Xcode will compile MiniLM.mlpackage to MiniLM.mlmodelc at build time")
