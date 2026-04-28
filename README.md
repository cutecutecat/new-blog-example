# 博客框架对照示例（Astro vs Hugo）

这个仓库包含四个静态博客示例项目，用来对比同一类内容在 **Astro** 和 **Hugo** 下的实现方式。

## 项目说明

1. `astro-examples/example-openai`
- Astro 版本的 OpenAI 风格示例。
- Vercel 线上地址：https://astro-openai.vercel.app/
- 可交互组件的特殊文章: https://astro-openai.vercel.app/release/introducing-gpt-5-5/

2. `astro-examples/example-hashnode`
- Astro 版本的 Hashnode 风格示例。
- Vercel 线上地址：https://astro-hashnode.vercel.app/
- 可交互组件的特殊文章: https://astro-hashnode.vercel.app/release/introducing-gpt-5-5/

3. `hugo-examples/example-openai`
- Hugo 版本的 OpenAI 风格示例。
- Vercel 线上地址：https://hugo-openai.vercel.app/

4. `hugo-examples/example-hashnode`
- Hugo 版本的 Hashnode 风格示例。
- Vercel 线上地址：https://hugo-hashnode.vercel.app/

## 部署到 Vercel（4 个站点）

为每个站点创建一个 Vercel Project（同一个 GitHub 仓库可连接多个项目）：

1. `astro-openai` -> Root Directory: `astro-examples/example-openai`
2. `astro-hashnode` -> Root Directory: `astro-examples/example-hashnode`
3. `hugo-openai` -> Root Directory: `hugo-examples/example-openai`
4. `hugo-hashnode` -> Root Directory: `hugo-examples/example-hashnode`

推荐设置：

1. Framework Preset：Astro 项目选 `Astro`，Hugo 项目选 `Hugo`
2. Production Branch：`main`
3. Preview：开启（默认），任意非 `main` 分支都会自动生成该项目的 preview URL

说明：

1. 已移除 GitHub Pages 的 CI 部署流程（`.github/workflows/pages.yml`）
2. 现在部署入口为 Vercel 的 Git 集成，不再通过 GitHub Actions 推送静态产物分支

## 快速运行

### Astro 项目

```bash
cd astro-examples/example-openai   # 或 example-hashnode
pnpm install
pnpm dev
```

### Hugo 项目

```bash
cd hugo-examples/example-openai    # 或 example-hashnode
hugo server -D
```

## Astro 和 Hugo 的主要差别

| 对比项 | Astro | Hugo |
| --- | --- | --- |
| 技术栈定位 | 偏前端工程化，适合现代 JS/TS 生态 | Go 编写的静态站点生成器，偏内容和模板驱动 |
| 模板/组件模型 | 以 `.astro` 组件为中心，组件化组织页面 | 以 `layouts` + partials 模板体系为中心 |
| 内容管理方式 | 常见在 `src/content`、`src/pages` 中管理 | 标准 `content/` + front matter + section/list/single |
| MDX 支持 | 原生支持 MDX，Markdown 中可直接嵌入组件与交互片段 | 默认不支持 MDX（主要是 Markdown + 短代码/模板） |
| MDX 影响范畴 | 影响内容表达能力、组件复用方式、内容与前端协作边界；适合“文档+交互”混合页面 | 影响较小，更偏纯内容发布流；交互通常通过模板、短代码或额外前端构建补充 |
| 构建输出目录 | 默认 `dist/` | 默认 `public/` |
| 扩展与生态 | 易接入 React/Vue/Svelte 等 UI 组件与 npm 生态 | 无需 Node 依赖即可高效构建，部署链路更轻量 |
| 适用场景 | 需要更强交互能力、组件化开发体验 | 更看重构建速度、简单部署、内容型站点稳定产出 |
