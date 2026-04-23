# Claude gag — claude_gag

**Fixture source:**

```ruby
def answer
  2 + 3
end
```

**Validation cases:**

- `answer` → `5`

## Iteration 1

**Prompt:**

```
p1
```

**Raw response:**

```
[["bad"]]
```

**Parsed IR:**

```json
[["bad"]]
```

**Validator errors:**
- instruction 0: unknown opcode :bad

## Iteration 2

**Prompt:**

```
p2
```

**Raw response:**

```
[["putobject",7],["leave"]]
```

**Parsed IR:**

```json
[["putobject",7],["leave"]]
```

**Validator errors:**
- iseq returned 7; expected 5

## Iteration 3

**Prompt:**

```
p3
```

**Raw response:**

```
[["putobject",5],["leave"]]
```

**Parsed IR:**

```json
[["putobject",5],["leave"]]
```

**Validator errors:** (none)

## Outcome: success
