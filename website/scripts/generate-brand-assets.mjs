// One-shot: rasterizes the brand mark (logo.svg) into the committed PNG
// assets, and regenerates the social cards. Run with:
//   aube run brand:assets
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import sharp from "sharp";

import {
  generateHomeSocialImage,
  generatePostSocialImages,
} from "./generate-social-images.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.resolve(__dirname, "..", "src", "assets");

const RASTERS = [
  { file: "logo.png", size: 512 },
  { file: "favicon-512.png", size: 512 },
  { file: "favicon-192.png", size: 192 },
  { file: "apple-touch-icon.png", size: 180 },
  { file: "favicon-32.png", size: 32 },
  { file: "favicon-16.png", size: 16 },
];

const svg = await fs.readFile(path.join(assetsDir, "logo.svg"));

for (const { file, size } of RASTERS) {
  const buffer = await sharp(svg, { density: 384 })
    .resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();
  await fs.writeFile(path.join(assetsDir, file), buffer);
  console.log(`wrote ${file} (${size}x${size})`);
}

await generateHomeSocialImage();
console.log("wrote social-card.png (1200x630)");

await generatePostSocialImages();
console.log("wrote per-post social cards");
