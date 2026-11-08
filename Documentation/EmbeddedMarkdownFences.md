# Embedded Markdown fences

Set `configuration.renderMarkdownCodeFences = true` to render closed fences tagged `markdown` in the same text view. The setting defaults to false. Longer backtick fences can enclose shorter fences, recursively. Delimiters remain editable source, and selection and undo use the single native editor.

The outer fence has no rail. Each nested level adds an ancestor-colored rail and a matching paragraph inset. Configure `configuration.codeBlock.markdownFenceRailWidth` and `markdownFenceShadeFractions` (a repeating array of blend fractions toward body text). Empty fractions use the ordinary code background. The defaults are 10 points and `[0, 0.065, 0.13, 0.195]`. Runtime changes rebuild styling.

Fence backgrounds draw in the text view background pass beneath native selection. Tables, images, and decorations use the remaining content width. HTML export continues to represent these as ordinary code fences.

Return completes a newly typed Markdown opening fence, except within ordinary code. Unclosed fences retain the upstream literal-text behavior. This feature does not add tilde fences or change upstream indentation rules for recognizing fence openers.

## Maintaining the fork

The feature branch starts at upstream `04f3dbd10d3d31e819eec6746cd24edb65b7a80e`. Keep parser rules, background drawing, and configuration helpers localized; preserve upstream Demo and package products. Test ordinary fences with the feature disabled as well as nested content.

The untouched baseline has one failing HTML autolink assertion: `www.example.com` expects HTTP while the renderer emits HTTPS. Track that independently of embedded fence changes.
