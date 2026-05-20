import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import matter from "gray-matter";
import sharp from "sharp";

const WIDTH = 1200;
const HEIGHT = 630;
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, "..");
const postsDir = path.join(rootDir, "src", "blog", "posts");
const assetsDir = path.join(rootDir, "src", "assets");
const outputDir = path.join(assetsDir, "social");

const COLORS = {
  bg: "#0a0a0b",
  panel: "#111113",
  border: "#232325",
  borderBright: "#34342f",
  fg: "#e8e6e3",
  muted: "#8d8d86",
  dim: "#5a5a55",
  accent: "#9d7ce0",
  prompt: "#4ade80",
};

const MONO =
  "ui-monospace, 'SF Mono', 'JetBrains Mono', 'Cascadia Code', Menlo, Consolas, monospace";

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function wrapText(text, maxLineLength, maxLines) {
  const words = String(text).trim().split(/\s+/).filter(Boolean);
  const lines = [];
  let current = "";

  for (const word of words) {
    const next = current ? `${current} ${word}` : word;

    if (next.length <= maxLineLength) {
      current = next;
      continue;
    }

    if (current) {
      lines.push(current);
      current = word;
    } else {
      lines.push(word);
    }

    if (lines.length === maxLines) {
      break;
    }
  }

  if (current && lines.length < maxLines) {
    lines.push(current);
  }

  if (lines.length === maxLines && words.join(" ").length > lines.join(" ").length) {
    lines[maxLines - 1] = lines[maxLines - 1].replace(/[,.!?;:]?$/, "") + "...";
  }

  return lines;
}

function formatDate(value) {
  if (!value) {
    return "Condukt Blog";
  }

  const date = value instanceof Date ? value : new Date(value);

  if (Number.isNaN(date.getTime())) {
    return "Condukt Blog";
  }

  return date.toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
}

// The brand mark (256x256 source) placed at (x, y), scaled to `size`.
function mark(x, y, size) {
  const s = size / 256;
  return `<g transform="translate(${x} ${y}) scale(${s})">
    <rect x="16" y="16" width="224" height="224" rx="52" fill="${COLORS.bg}" stroke="${COLORS.accent}" stroke-width="10"/>
    <polyline points="74,84 124,128 74,172" stroke="${COLORS.accent}" stroke-width="22" stroke-linecap="round" stroke-linejoin="round"/>
    <rect x="132" y="156" width="54" height="20" rx="6" fill="${COLORS.accent}"/>
  </g>`;
}

function renderCard({ eyebrow, title, footnote }) {
  const lines = wrapText(title, 22, 3);
  const fontSize = lines.length >= 3 ? 62 : lines.length === 2 ? 72 : 78;
  const lineHeight = Math.round(fontSize * 1.16);
  const blockHeight = lines.length * lineHeight;
  const titleTop = 360 - blockHeight / 2 + fontSize * 0.34;
  const titleLines = lines
    .map(
      (line, index) =>
        `<tspan x="126" y="${Math.round(titleTop + index * lineHeight)}">${escapeHtml(line)}</tspan>`
    )
    .join("");

  return `
<svg width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}" xmlns="http://www.w3.org/2000/svg">
  <rect width="${WIDTH}" height="${HEIGHT}" fill="${COLORS.bg}"/>
  <g stroke="${COLORS.border}" stroke-width="1">
    <path d="M0 64H1200M0 128H1200M0 192H1200M0 256H1200M0 320H1200M0 384H1200M0 448H1200M0 512H1200M0 576H1200"/>
    <path d="M64 0V630M128 0V630M192 0V630M256 0V630M320 0V630M384 0V630M448 0V630M512 0V630M576 0V630M640 0V630M704 0V630M768 0V630M832 0V630M896 0V630M960 0V630M1024 0V630M1088 0V630M1152 0V630"/>
  </g>
  <rect x="56" y="48" width="1088" height="534" rx="18" fill="${COLORS.panel}" stroke="${COLORS.border}" stroke-width="1.5"/>
  <rect x="56" y="48" width="1088" height="56" rx="18" fill="${COLORS.bg}" fill-opacity="0.45"/>
  <line x1="56" y1="104" x2="1144" y2="104" stroke="${COLORS.border}" stroke-width="1.5"/>
  <circle cx="92" cy="76" r="7" fill="${COLORS.borderBright}"/>
  <circle cx="116" cy="76" r="7" fill="${COLORS.borderBright}"/>
  <circle cx="140" cy="76" r="7" fill="${COLORS.borderBright}"/>
  <text x="172" y="83" font-family="${MONO}" font-size="20" fill="${COLORS.dim}">~/condukt</text>
  ${mark(1060, 56, 40)}
  <text x="126" y="186" font-family="${MONO}" font-size="24" fill="${COLORS.dim}">${escapeHtml(eyebrow)}</text>
  <text x="78" y="${Math.round(titleTop)}" font-family="${MONO}" font-size="${fontSize}" font-weight="700" fill="${COLORS.prompt}">❯</text>
  <text font-family="${MONO}" font-size="${fontSize}" font-weight="700" fill="${COLORS.fg}">${titleLines}</text>
  <text x="126" y="520" font-family="${MONO}" font-size="24" fill="${COLORS.muted}">${escapeHtml(footnote)}</text>
  <text x="1106" y="520" text-anchor="end" font-family="${MONO}" font-size="22" fill="${COLORS.accent}">condukt.tuist.dev</text>
</svg>`;
}

async function writeIfChanged(outputPath, buffer) {
  let existing;
  try {
    existing = await fs.readFile(outputPath);
  } catch {
    existing = null;
  }
  if (!existing || !existing.equals(buffer)) {
    await fs.writeFile(outputPath, buffer);
  }
}

async function renderPostImage(postPath) {
  const slug = path.basename(postPath, path.extname(postPath));
  const source = await fs.readFile(path.join(postsDir, postPath), "utf8");
  const { data } = matter(source);

  if (!data.title) {
    return null;
  }

  const svg = renderCard({
    eyebrow: "# condukt blog",
    title: data.title,
    footnote: formatDate(data.date),
  });
  const image = await sharp(Buffer.from(svg)).png().toBuffer();
  await writeIfChanged(path.join(outputDir, `${slug}.png`), image);
  return `${slug}.png`;
}

export async function generatePostSocialImages() {
  await fs.mkdir(outputDir, { recursive: true });

  const posts = (await fs.readdir(postsDir))
    .filter((file) => file.endsWith(".md"))
    .sort();
  const expected = new Set();

  for (const post of posts) {
    const output = await renderPostImage(post);
    if (output) {
      expected.add(output);
    }
  }

  const generated = (await fs.readdir(outputDir)).filter((file) =>
    file.endsWith(".png")
  );

  await Promise.all(
    generated
      .filter((file) => !expected.has(file))
      .map((file) => fs.rm(path.join(outputDir, file)))
  );
}

export async function generateHomeSocialImage() {
  const svg = renderCard({
    eyebrow: "# elixir · agents · sandboxes",
    title: "Define and run AI agents.",
    footnote: "Supervised · Sandboxed · Elixir",
  });
  const image = await sharp(Buffer.from(svg)).png().toBuffer();
  await writeIfChanged(path.join(assetsDir, "social-card.png"), image);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await generatePostSocialImages();
  await generateHomeSocialImage();
}
