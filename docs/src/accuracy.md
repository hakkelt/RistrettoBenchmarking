# Time to accuracy

The time each toolbox needs to bring its error below a common target, at its own calibrated λ (see
[Time to accuracy and fixed budget](@ref) for the target and the iteration ladders). A cell holds the
time, the iteration count that first reached the target and, in brackets, the error reached there.
For BART, the count is its `-i` budget, about the number of normal-operator applications.

## Komondor, CPU

The 8-thread snapshot is shown; the other thread counts open below it.

```@eval
Main.Tables.race()
```

## Komondor, GPU

```@eval
Main.Tables.race(; gpu = true)
```

```@eval
Main.Tables.other_races()
```

```@eval
Main.Tables.other_races(; gpu = true)
```
