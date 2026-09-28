# Installed Codex desktop static reference

For 0.3.0, the user-provided full-app screenshots take precedence for the outer shell, navigation, theme accents and inspector. This earlier spec describes a different inner-workspace variant; see [DESIGN.md](../DESIGN.md) for the corrected application scope.

Read-only inspection on 2026-09-28. Actual app is `/Applications/ChatGPT.app`, bundle identifier `com.openai.codex`, version `26.924.22138`, build `11645`. The static archive is `/Applications/ChatGPT.app/Contents/Resources/app.asar`. No application was launched, foregrounded, controlled, or screen-captured; no account settings, chats, or private database was read.

All archive-relative evidence paths below start with `webview/assets/`. These are measurements and source interpretations, not an exact visual reference screenshot. The installed app includes Codex, Work, browser, compact, feature-gated, and customized theme variants. This spec describes the normal desktop Codex defaults; runtime user settings and active experiments were intentionally not queried.

## Main layout

- Sidebar preferred width275px, clamped minimum240px/maximum520px and leaving at least320px for main content.
- Toolbar46px; titlebar44px; small toolbar36px; pane toolbar40px. Toolbar horizontal padding16px. These are tokens, not additive stacked heights.
- Desktop thread/composer shared wrapper maximum48rem=768px INCLUDING16px horizontal inset per side, because all elements are border-box. Actual transcript/card maximum736px. Native wrapper n9 (app-primary export Tt, thread-scroll import ve) adds 2×thread-body-inline-padding to max-width, but this extra padding variable is set only for browser; Electron falls back0. SwiftUI padding16 BEFORE frame(maxWidth:768); CSS max-width768 plus padding16 with border-box. Separate home suggestion wrappers use px-panel20, not this composer width.
- System sans: Apple system, BlinkMacSystemFont, Segoe UI, sans-serif. UI default14px, weight430; medium500. Electron small13px, extra-small12px. Chat default14px, code default12px. Root spacing unit4px.
- Normal Codex home heading28px regular, line-height1.2. Text: “What should we build?”; zh-CN exactly “我们要构建什么？”. Git-project translation: “你想让我们在 <projectSelect>{projectName}</projectSelect> 中构建什么？”; non-git: “我们应该在<projectSelect>{projectName}</projectSelect>中做些什么？”. Work home is a different heading and must not be substituted.
- Home heading group minimum-height112px, text aligned at bottom, internal vertical gap24px. Home composer anchor uses max(0,42svh/windowZoom − main-content top inset). It is not simply vertically centered.

Evidence: `app-shared-fa3f1d5d5942.css`, `app-initial-d817715f10a0.js`, `app-primary-cca0c1a58f0f.js` (D9t, n9 and home-composer-anchor), `thread-scroll-layout-b0a473da34bb.js` (ve shared composer/transcript wrapper), `zh-CN-1adc76a05252.js`.

## Sidebar

- Navigation rows30px, radius10px, horizontal cell padding8px, icon16px, icon-label gap8px. Text is Electron text-sm=13px. New chat is a normal row with compose icon, not a large filled primary button. Chinese label exactly “新聊天”. Search is a separate row.
- Other destinations (Tasks, Library, Skills/Plugins and others) are gated by actual product capability/experiments. Avoid adding nonfunctional destinations merely to imitate them.
- Normal navigation header gap0, scroll top inset4px. Sidebar scroll section gap16px; outer section inset8px. Base section heading14px medium, tertiary color at75% opacity; heading-to-list gap4px. Toggle vertical padding2px.
- Unified sidebar supports Pinned, Recents, Projects together. A preference can include project chats in Recents as well as their project. Other variants support By project / By connection / In one list organization. Do not assume Recents and Projects are always mutually exclusive tabs.
- Thread age uses12px tertiary and is hover-only in some variants. Thread text generally small13px.
- Profile footer normal label14px with18px avatar; rail avatar24px. Optional ambient usage subtext expands height. Footer height is measured at runtime; fixed52px two-line layout is not a confirmed universal value.
- Icon source assets use24x24 view boxes; desktop row rendering uses16px. Monochrome foreground/current-color treatment; no colored avatar or heavy icon tile required for ordinary navigation.

Evidence: `app-initial-d817715f10a0.js` (KP, p3, mta, profileFooter/OTi); shared CSS `.sidebar-navigation`, `.icon-xs`. `chat-compose-12a249689f7c.svg`, `sidebar-cd36807cc9f2.svg`, `codex-d905da579253.svg`. Official asset geometry was inspected but not copied into the product.

## Default theme palette

Colors derived from desktop default theme xK and theme conversion functions SRr/CRr/TRr/DRr, with default contrast45 light /60 dark, rather than sampled from the screen.

| Token | Light | Dark |
|---|---|---|
| Main surface | #ffffff | #181818 |
| Sidebar / surface-secondary | #f6f6f6 | #141414 |
| Normal composer | #ffffff | #363636 |
| Foreground | #1a1c1f | #dfdfdf |
| Secondary text | rgba(26,28,31,.695) | rgba(255,255,255,.71) |
| Tertiary text | rgba(26,28,31,.495) | rgba(255,255,255,.498) |
| Border | rgba(26,28,31,.078) | rgba(255,255,255,.084) |
| Strong border | rgba(26,28,31,.117) | rgba(255,255,255,.156) |
| Subtle border | rgba(26,28,31,.049) | rgba(255,255,255,.042) |
| Primary ghost hover / code block fill | rgba(26,28,31,.0535) | rgba(255,255,255,.078) |

Default neutral user bubble is foreground at5% opacity, composited over its surface. Account theme personalization can change user bubble and submit colors; such personalization was not inspected. Native dark composer specifically selects elevated-primary-opaque, explaining #363636 rather than a generic secondary surface.

Evidence: `app-initial-d817715f10a0.js` (xK, SRr, CRr, TRr, DRr); `app-shared-fa3f1d5d5942.css` theme token mappings and composer root rules.

## Composer

- Normal radius22px, no ordinary border. Light shadow: 0 0 0 1px #0000000a, 0 2px 8px #0000000a, 0 4px 80px 8px #00000006. Dark shadow: inset 0 0 1px #ffffff33. A border1px canvastext / shadow-none rule applies only to forced-colors accessibility mode and must not be treated as normal appearance.
- Multiline editor minimum44px; line-height20px; horizontal padding12px. Empty attachment strip top8px, horizontal8px, bottom6px (there is an earlier8px bottom declaration; final shared style is6). Input-to-footer gap4px.
- Footer horizontal padding8px/bottom8px; default control28px, comfortable32px; grid/control gap5px. Send is round, disabled opacity50%, with8px leading separation from preceding controls.
- Native Codex cGt: leading add-context button plus optional permission/environment/goal controls; trailing model/intelligence with integrated reasoning, optional context/IDE status, dictation, send. Width and flags adapt visibility. Do not infer ChatGPT control ordering from the separate chatgpt composer.
- Utility bar contains working context such as local/worktree/project/branch. Its position is variant-sensitive: normal Codex home actionBarPosition resolves above, Work home below. Avoid hardcoding the Work interpretation as Codex.

Evidence: shared CSS ComposerLayoutRoot_1086j; `app-primary-cca0c1a58f0f.js` XZ/ZZ/cGt/gGt/qZ; `composer-utility-bar-c4d6c9bca0c5.js` kc.

## Transcript

- Markdown family qhsrt is the native current renderer. Generic markdown-9f1e6043ad02.css is a separate family and should not be mixed into this reference.
- Chat14px, line-height1.625=22.75px. Markdown space base3.5px. Adjacent paragraph margin14px. Code-block margin17.5px.
- Native user bubble: max70% width, radius22px, padding10px vertical/16px horizontal. Compact variant only: max456px, radius16px, padding8px/12px.
- Inline code: mono .92em; radius6px; padding1px vertical/6px horizontal. Fill mixes primary-ghost-hover60% and foreground6% in sRGB.
- Standard native code block:20px corner radius (superellipse1.1), subtle1px border, primary-ghost-hover fill. Header minimum48px, vertical padding6px, leading16px (md20), trailing6px, gap8px,13px medium text. Code body top0/bottom12px/horizontal16px (md20); code12px and line-height20px. Without header body uses16px vertical padding.
- Table current renderer uses horizontal borders; header padding7px vertical, cells8.75px vertical, trailing column spacing21px. Header border strong, row border subtle. Small table font is max(code size,chat*.875)=12.25px at defaults.

Evidence: `app-primary-75218b12d1d9.css` qhsrt; `user-message-b53f167a4396.js` + `user-message-101e92976aee.css`; `app-shared-36eae88777f2.js` yai and adjacent code shell/Cai; shared CSS _Surface_224c4/_CodeContent_224c4.

## Verification limits

A safe background static renderer can use a component skeleton and these measurements to produce a useful reconstruction without executing app IPC or accessing user data. Such an image validates the reconstruction only; it is not an exact screenshot of the installed Codex surface. Native titlebar material and traffic-light positions, active sidebar variant, user theme settings, and exact live component choices remain unsampled. Do not claim pixel-identical UI from this inspection alone.
