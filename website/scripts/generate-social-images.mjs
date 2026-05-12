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
const outputDir = path.join(rootDir, "src", "assets", "social");
const logoPath = path.join(rootDir, "src", "assets", "logo.png");

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

function renderSvg({ title, date }) {
  const lines = wrapText(title, 25, 3);
  const fontSize = lines.length >= 3 ? 60 : 70;
  const lineHeight = Math.round(fontSize * 1.12);
  const titleTop = lines.length === 1 ? 310 : lines.length === 2 ? 276 : 248;
  const titleLines = lines
    .map(
      (line, index) =>
        `<tspan x="390" y="${titleTop + index * lineHeight}">${escapeHtml(line)}</tspan>`
    )
    .join("");

  return `
<svg width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0b0d10"/>
      <stop offset="0.56" stop-color="#111820"/>
      <stop offset="1" stop-color="#0c1117"/>
    </linearGradient>
    <radialGradient id="glow" cx="58%" cy="30%" r="70%">
      <stop offset="0" stop-color="#1dd5bd" stop-opacity="0.22"/>
      <stop offset="0.5" stop-color="#7458ff" stop-opacity="0.10"/>
      <stop offset="1" stop-color="#0b0d10" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="${WIDTH}" height="${HEIGHT}" rx="34" fill="url(#bg)"/>
  <rect width="${WIDTH}" height="${HEIGHT}" rx="34" fill="url(#glow)"/>
  <path d="M0 124H1200M0 506H1200" stroke="#ffffff" stroke-opacity="0.05"/>
  <path d="M90 0V630M1110 0V630" stroke="#ffffff" stroke-opacity="0.04"/>
  <circle cx="230" cy="318" r="165" fill="#ffffff" fill-opacity="0.035"/>
  <text x="390" y="190" font-family="Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" font-size="31" font-weight="800" letter-spacing="9" fill="#1dd5bd">CONDUKT</text>
  <text font-family="Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" font-size="${fontSize}" font-weight="800" fill="#ffffff">${titleLines}</text>
  <text x="390" y="490" font-family="Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" font-size="29" font-weight="600" fill="#aeb8c4">${escapeHtml(formatDate(date))}</text>
  <text x="390" y="540" font-family="Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif" font-size="25" font-weight="600" fill="#7d8591">condukt.tuist.dev</text>
</svg>`;
}

async function renderPostImage(postPath, logoBuffer) {
  const slug = path.basename(postPath, path.extname(postPath));
  const source = await fs.readFile(path.join(postsDir, postPath), "utf8");
  const { data } = matter(source);

  if (!data.title) {
    return null;
  }

  const image = await sharp(Buffer.from(renderSvg(data)))
    .composite([{ input: logoBuffer, left: 106, top: 222 }])
    .png()
    .toBuffer();

  const outputPath = path.join(outputDir, `${slug}.png`);
  let existing;

  try {
    existing = await fs.readFile(outputPath);
  } catch {
    existing = null;
  }

  if (!existing || !existing.equals(image)) {
    await fs.writeFile(outputPath, image);
  }

  return `${slug}.png`;
}

export async function generatePostSocialImages() {
  await fs.mkdir(outputDir, { recursive: true });

  const posts = (await fs.readdir(postsDir))
    .filter((file) => file.endsWith(".md"))
    .sort();
  const logoBuffer = await sharp(logoPath)
    .resize(220, 220, { fit: "contain" })
    .png()
    .toBuffer();
  const expected = new Set();

  for (const post of posts) {
    const output = await renderPostImage(post, logoBuffer);

    if (output) {
      expected.add(output);
    }
  }

  const generated = (await fs.readdir(outputDir)).filter((file) => file.endsWith(".png"));

  await Promise.all(
    generated
      .filter((file) => !expected.has(file))
      .map((file) => fs.rm(path.join(outputDir, file)))
  );
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await generatePostSocialImages();
}
