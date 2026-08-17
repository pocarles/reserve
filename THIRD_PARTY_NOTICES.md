# Third-party notices

## Code provenance

Reserve contains small adapted implementation patterns informed by
[CodexBar](https://github.com/steipete/CodexBar), inspected at commit
`89ee92124fdab4fe353ffeb48daba9be655fc70d`.

CodexBar is distributed under the following license:

> MIT License
>
> Copyright (c) 2026 Peter Steinberger
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

No CodexBar WebKit integration, cookie extraction, raw history database,
widget, executable updater, or provider-registry implementation is included.

## Sparkle

Reserve bundles [Sparkle 2.9.5](https://github.com/sparkle-project/Sparkle)
for signed, user-approved macOS updates. Sparkle and its included third-party
components are distributed under the licenses in the bundled
`Sparkle-LICENSE.txt` file. Reserve removes Sparkle's sandbox-only XPC services
because Reserve is not sandboxed.

## Provider names and marks

OpenAI, Codex, Anthropic, Claude, xAI, Grok, and their associated marks belong
to their respective owners. Their appearance is descriptive and does not imply
affiliation, sponsorship, or endorsement.

Reserve bundles unmodified provider marks obtained from first-party sources on
August 16, 2026:

- the transparent OpenAI Blossom Black SVG from the official
  [OpenAI logo download](https://cdn.openai.com/brand/openai-logos.zip), used
  according to the [OpenAI design guidelines](https://openai.com/brand/). Its
  transparent canvas is cropped to the mark's content bounds for legibility at
  macOS status-item sizes; the first-party path geometry is unchanged;
- Claude Spark - Clay from the press kit linked by the
  [Anthropic newsroom](https://www.anthropic.com/news); and
- the Grok mark published on the
  [xAI brand guidelines](https://x.ai/legal/brand-guidelines) page. Its
  first-party SVG uses `currentColor`, which Reserve resolves to the surrounding
  macOS label or menu-bar colour.

An open-source software license covering code or artwork from another project
does not grant permission to use a provider's trademarks. The previously
adapted provider SVGs remain excluded. Provider marks are used only to identify
their corresponding services and must not imply affiliation or endorsement.

Reserve is an independent open-source project and is not affiliated with,
endorsed by, sponsored by, or an official product of OpenAI, Anthropic, or xAI.
