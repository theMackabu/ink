# Fast Markdown Parser #

This is a **bold** statement with _italic_ text. <br/>
Here's some `inline code` too.

Features
--------

- Fast parsing with **Zig**!
- Minimal memory allocations
- Support for [links](https://example.com)

### Nested **Bold and _Italic_**

---

1. ordered one
2. ordered two
3. ordered three

Regular paragraph with multiple inline elements.

> Block quote with `inline code` and **bold**
>
> - list one
> - list two
>  - nested list one
>  - nested list two
>
> 1. ordered one
> 2. ordered two
>
> - [ ] unchecked task
> - [x] checked task
>
> Check out [this link](https://example.com) for more
>
> Here's _italic_ and ***bold italic*** together

- [ ] unchecked task
- [x] checked task

Have some code
==============

```javascript
const world = "world"
console.log(`hello ${world}`)
```

~~~c
#include <stdio.h>
#include <stdlib.h>

int main() {
  fputs("Hello World!", stdout);
  return EXIT_SUCCESS;
}
~~~
