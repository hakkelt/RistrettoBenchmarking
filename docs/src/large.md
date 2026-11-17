# Large datasets

Ristretto alone on two acquisitions too large for the comparison suite: a 3D knee and a multi-slice
radial breast series, at 1, 4, 8 and 16 threads (one exclusive Komondor node per case and thread
count) and on an A100. λ is fixed per case and method. Results and logs:
[`benchmark/paper_part6/large_datasets/`](https://github.com/hakkelt/RistrettoBenchmarking/tree/master/benchmark/paper_part6/large_datasets).

```@eval
Main.Tables.md(Main.Tables.large_markdown())
```

On the GPU, the breast series is solved jointly over its slices, while the CPU splits it into one task
per slice; the two therefore solve different problems and reach different errors.
