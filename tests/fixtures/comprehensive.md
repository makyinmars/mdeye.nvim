# Heading One

Some *emphasis* and **strong text** and ~~strikethrough~~ and `inline code` here.
This paragraph continues on a second source line
and a third source line that should reflow.

## Heading Two

A [link label](https://example.com/page) and a [relative link](./docs/other.md) and
an autolink <https://autolink.example.com> and ![an image](./img/pic.png).

### Heading Three

Hard break at the end of this line\
continues after a backslash hard break.

#### Heading Four

##### Heading Five

###### Heading Six

- unordered item one
- unordered item two with *emphasis
  spanning a source line break*
  - nested item a
  - nested item b
    1. deep ordered one
    2. deep ordered two

1. ordered first
2. ordered second wraps onto
   a continuation line
3. ordered third

- [ ] unchecked task
- [x] checked task

> A block quote paragraph with **strong
> text spanning the quote line break** and more prose that should reflow
> within the quote gutter.
>
> > Nested quote with *emphasis
> > across nested quote lines* here.

```lua
local function hello(name)
  return ("hello %s"):format(name)
end
```

```
plain fence without language
```

| Column A | Column B | Column C |
| :------- | :------: | -------: |
| left     | center   | right    |
| *em*     | `code`   | [t](x.md) |
| 宽字符   | emoji 🚀 | plain    |

---

Unicode paragraph: 日本語のテキストと emoji 🚀🎉 and combining é (e + ́ ) plus more
ASCII text to force wrapping across display-cell boundaries.

<div class="raw">
raw html block
</div>

Inline <span>html</span> in a paragraph.

Final paragraph after everything. Return to [Heading Two](#heading-two) or read a note[^reader].

[^reader]: A footnote with **formatted context** and a relative [reference](./notes.md).
