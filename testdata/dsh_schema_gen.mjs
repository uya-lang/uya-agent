// testdata/dsh_schema_gen.mjs — 生成 `src/web/dwhschema.uya`（DSH 的 `llm-pi-ai`
// 配置 schema 的 schemastery 信封）。
//
// 为什么要生成而不是手写：设置页把 `settings.describe` 回来的 `namespaces[].schema`
// 交给 `@deepseek-ai/schemastery` 的 `new Schema(envelope)` **反序列化**，再拿它做
// 路径解析（`nodeAtPath(root, ["providers", "\0probe", "api"])` —— 「添加自定义提供方」
// 卡片的协议下拉框就靠它）与值校验。手写一份就等于把 DSH 的 schema 抄一遍：抄漏一个
// 内层节点时，症状是「那个卡片根本不出来」或「提交被拒绝」，而**没有任何报错线索**。
// 所以信封**从真 DSH 里导出**，本脚本同时把它自己验一遍（rehydrate + union + 校验一个
// 真实 profile），验不过就退出非零 —— 生成物与生成器一起进仓，升级 DSH 时重跑即可。
//
//   node testdata/dsh_schema_gen.mjs            # 写 src/web/dwhschema.uya
//   node testdata/dsh_schema_gen.mjs --check    # 只验，不写（CI/自测用）
//
// 找包：先按 `DSH_PKG_ROOT`，再按本机 `~/.npm-global/lib/node_modules/@deepseek-ai/dsh`。

import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "..");
const checkOnly = process.argv.includes("--check");

/** 本机 DSH 安装根（`node_modules/@deepseek-ai/dsh` 那个目录）。 */
function pkgRoot() {
    if (process.env.DSH_PKG_ROOT) return process.env.DSH_PKG_ROOT;
    return join(process.env.HOME ?? "/root",
        ".npm-global/lib/node_modules/@deepseek-ai/dsh");
}

/** 从 DSH 的安装树里加载一个包（它自己带 node_modules）。 */
async function loadFromHarness(name) {
    const require = createRequire(join(pkgRoot(), "package.json"));
    const resolved = require.resolve(name);
    return import(resolved.startsWith("file:") ? resolved : `file://${resolved}`);
}

const piAi = await loadFromHarness("@deepseek-ai/dsh-llm-pi-ai");
const schemastery = await loadFromHarness("@deepseek-ai/schemastery");
const Schema = schemastery.default ?? schemastery;

/** 一份代表性 profile：**本仓写进文档的形状**（opencode 那条路线）。 */
const SAMPLE = {
    displayName: "opencode zen",
    apiKeyEnv: "OPENCODE_API_KEY",
    api: "openai-responses",
    baseURL: "https://opencode.ai/zen/go/v1/",
    models: [{ id: "deepseek-v4.1-flash", name: "deepseek-v4.1-flash", contextWindow: 1000000 }],
};

/** 信封 → 活节点（客户端 `SettingsSchemaService.rehydrate` 做的就是这件事）。 */
function rehydrate(envelope) {
    return new Schema(envelope);
}

/** 按客户端的 `nodeAtPath` 走一条路径（`ui-settings` 的同名实现，逐行照抄）。 */
function nodeAtPath(root, path) {
    let node = root;
    for (const key of path) {
        if (node === undefined) return undefined;
        if (node.type === "object") node = node.dict?.[key];
        else if (node.type === "dict" || node.type === "array") node = node.inner;
        else return undefined;
    }
    return node;
}

const envelope = piAi.Config.toJSON();
const node = rehydrate(envelope);
const api = nodeAtPath(node, ["providers", "\u0000probe", "api"]);
if (api?.type !== "union" || !Array.isArray(api.list)) {
    console.error("dsh-schema-gen: providers.*.api 不是 union —— 客户端的协议下拉框会空掉");
    process.exit(1);
}
const protocols = api.list.map((entry) => entry.value).filter((v) => typeof v === "string");
if (!protocols.includes("openai-responses")) {
    console.error(`dsh-schema-gen: 协议清单里没有 openai-responses：${protocols.join(",")}`);
    process.exit(1);
}
const root = rehydrate(envelope);
const providers = nodeAtPath(root, ["providers"]);
if (providers?.type !== "dict") {
    console.error("dsh-schema-gen: providers 不是 dict —— 设置页整块认不出来");
    process.exit(1);
}
// 值校验：本仓写进文档的那个形状必须过（过不了 ⇒ 页面提交全被自己挡住）
const rootWithSample = rehydrate(envelope);
const provider = nodeAtPath(rootWithSample, ["providers", "\u0000probe"]);
const failure = (() => {
    try {
        provider(SAMPLE);
        return undefined;
    } catch (error) {
        return error instanceof Error ? error.message : String(error);
    }
})();
if (failure !== undefined) {
    console.error(`dsh-schema-gen: 样例 profile 过不了 schema：${failure}`);
    process.exit(1);
}

const text = JSON.stringify(envelope);
console.log(`dsh-schema-gen: 信封 ${text.length} B / ${Object.keys(envelope.refs).length} 个节点；`
    + `协议 ${protocols.length} 个；样例校验通过`);

if (!checkOnly) {
    // 嵌进 .uya：把 JSON **转义后的**文本按 token 边界断行。分两件事：
    //   ① Uya 的词法器对**单个字符串字面量**有 4096 字节的上限（实测：5000 字节的字面量
    //      连语法分析都过不去，报「当前 token 为 null」）⇒ 整段信封必须切成几个常量；
    //   ② 每个物理行 ≤ 78 字符（AGENTS.md 的行宽指标）。
    // 字面量支持真实换行，所以每个片段仍是一段可以直接 `buf_append_cstr` 的多行常量。
    const lines = wrapEscaped(envelope, 74, 42).split("\n");
    const chunks = [];
    let cur = [];
    let used = 0;
    for (const line of lines) {
        const size = Buffer.byteLength(line, "utf8") + 5;   // 缩进 4 + 换行
        if (cur.length > 0 && used + size > 3000) {
            chunks.push(cur);
            cur = [];
            used = 0;
        }
        cur.push(line);
        used += size;
    }
    if (cur.length > 0) chunks.push(cur);
    // 字面量的**首尾各留一个空行**：声明那一行（`const … = "`）与收尾那一行
    // （`" as &const byte;`）于是各自独占一行，都不用压 JSON 内容的宽度
    // （JSON 允许 token 之间任意空白，空行无害）。
    const decls = chunks.map((chunk, i) =>
        `const DWH_SCHEMA_${String(i + 1)}: &const byte = "\n`
        + chunk.map((l) => `    ${l}`).join("\n")
        + `\n" as &const byte;`).join("\n\n");
    const appends = chunks.map((_chunk, i) =>
        `    if (!buf_append_cstr(out, DWH_SCHEMA_${String(i + 1)})) {\n`
        + `        return false;\n    }`).join("\n");
    const body = `// src/web/dwhschema.uya — DSH 的 \`llm-pi-ai\` 配置 schema（schemastery 信封）
//
// 本文件：**一段机器生成的 JSON**（\`DWH_SCHEMA_1..N\`）与它的取用口（\`dwh_schema_json\`）。
// 为什么是原样嵌一段 JSON 而不是手写结构：设置页把 \`settings.describe\` 回来的
//   \`namespaces[].schema\` 交给 schemastery 的 \`new Schema(envelope)\` 反序列化，
//   再拿它做**路径解析**（\`nodeAtPath(root, ["providers", "\\0probe", "api"])\` ——
//    「添加自定义提供方」卡片的协议下拉框就靠它）与**值校验**。手写一份等于把 DSH 的
//   schema 抄一遍：抄漏一个内层节点时，症状是「那个卡片根本不出来」或「提交被拒绝」，
//   而**没有任何报错线索**。
// 为什么分成 ${String(chunks.length)} 段：Uya 的词法器对**单个字符串字面量**有 4096 字节的上限
//   （实测：5000 字节的字面量连语法分析都过不去，报「当前 token 为 null」），而这份
//   信封是 9.5 KB 量级。切点都在 JSON 的 token 边界上，拼回来就是原文（顺序即数组序）。
// 生成方式：\`node testdata/dsh_schema_gen.mjs\`（从本机 DSH 的
//   \`@deepseek-ai/dsh-llm-pi-ai\` 里 \`Config.toJSON()\` 导出），同一个脚本顺手验三件事：
//   ① 信封能被真 schemastery 反序列化；② \`providers.*.api\` 是 union 且含
//   \`openai-responses\`；③ 一份代表性的 provider profile 能过校验。升级 DSH 之后
//   重跑它（\`--check\` 只验不写），别手改这个文件。
// 依赖：无 \`use\` 行（合并命名空间）；本仓 foundation/bufx（\`buf_append_cstr\`）。
// 命名：\`DWH_SCHEMA_N\`（信封片段）、\`dwh_schema_json\`（按序拼进 out）。

// 行宽豁免：这是一整块机器生成的 JSON（转义后的引号每个占 2 个字符），
// 已经按 token 边界断过行，仍然超宽的那些行**不可再断**。
${decls}

// 把信封原文写进 out（调用方自己拼 \`namespaces[].schema\` 那个字段）。
export fn dwh_schema_json(out: &Buf) bool {
${appends}
    return true;
}
`;
    writeFileSync(join(repo, "src/web/dwhschema.uya"), body);
    console.log(`dsh-schema-gen: 已写 src/web/dwhschema.uya（${chunks.length} 段）`);
}

/**
 * 把信封转义成 Uya 字符串字面量的正文并按 token 边界断行。
 *
 * 断点只在**字符串外**的 `,`/`{`/`[`/`:` 之后（在字符串中间断行会把 JSON 写坏，
 * 而那种坏法只在客户端解析时才炸）；一行放不下一个长 token 时**让它超**（宁可超宽
 * 也不能断在 token 中间）。续行前面补两个空格 —— JSON 允许 token 之间任意空白。
 *
 * @param value - 信封对象。
 * @param limit - 续行的上限（含两格续行缩进）。
 * @param firstLimit - 首行的上限（它前面还压着 `const … = "` 那段声明）。
 * @returns 已转义的正文（含真实换行）。
 */
function wrapEscaped(value, limit, firstLimit) {
    const json = JSON.stringify(value);
    let out = "";
    const cuts = [];                 // out 里的安全断点
    let inString = false;
    for (let i = 0; i < json.length; i++) {
        const ch = json[i];
        if (inString) {
            if (ch === "\\") {
                // JSON 的转义序列要**整段**再转义一次：`\n` 到了 Uya 源码里就成了真换行
                const pairBody = json[i + 1] === "\"" ? "\\\"" : json[i + 1];
                out += "\\\\" + pairBody;
                i++;
                continue;
            }
            if (ch === "\"") {
                inString = false;
                out += "\\\"";
                cuts.push(out.length);
                continue;
            }
            out += ch;
            continue;
        }
        if (ch === "\"") {
            inString = true;
            out += "\\\"";
            continue;
        }
        out += ch;
        if (",[{".includes(ch)) cuts.push(out.length);
    }
    const lines = [];
    let start = 0;
    let next = 0;
    while (start < out.length) {
        const budget = start === 0 ? firstLimit : limit - 2;
        let cut = -1;
        while (next < cuts.length && cuts[next] - start <= budget) {
            cut = cuts[next];
            next++;
        }
        if (cut <= start) {
            cut = cuts[next] ?? out.length;      // 放不下一个长 token：让它超
            next++;
        }
        lines.push((start === 0 ? "" : "  ") + out.slice(start, cut));
        start = cut;
        while (next < cuts.length && cuts[next] <= start) next++;
    }
    return lines.join("\n");
}
