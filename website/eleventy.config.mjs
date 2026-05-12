import { createHighlighter } from "@lumis-sh/lumis";
import { htmlInline } from "@lumis-sh/lumis/formatters";
import bash from "@lumis-sh/lumis/langs/bash";
import elixir from "@lumis-sh/lumis/langs/elixir";
import hcl from "@lumis-sh/lumis/langs/hcl";
import theme from "@lumis-sh/themes/catppuccin_mocha";

import { generatePostSocialImages } from "./scripts/generate-social-images.mjs";

const LANGUAGES = { bash, elixir, hcl };

let highlighterPromise;
function getHighlighter() {
  if (!highlighterPromise) {
    highlighterPromise = createHighlighter({
      languages: Object.values(LANGUAGES),
    });
  }
  return highlighterPromise;
}

export default function (eleventyConfig) {
  eleventyConfig.addPassthroughCopy({ "src/assets": "assets" });
  eleventyConfig.addPassthroughCopy({ "src/static": "/" });

  eleventyConfig.addWatchTarget("src/assets/");
  eleventyConfig.addWatchTarget("src/blog/posts/");

  eleventyConfig.on("eleventy.before", async () => {
    await generatePostSocialImages();
  });

  eleventyConfig.addFilter("readableDate", (value) => {
    const date = value instanceof Date ? value : new Date(value);
    return date.toLocaleDateString("en-US", {
      year: "numeric",
      month: "long",
      day: "numeric",
      timeZone: "UTC",
    });
  });

  eleventyConfig.addFilter("htmlDateString", (value) => {
    const date = value instanceof Date ? value : new Date(value);
    return date.toISOString().slice(0, 10);
  });

  eleventyConfig.addPairedAsyncShortcode("highlight", async function (
    content,
    lang = "elixir"
  ) {
    const language = LANGUAGES[lang];
    if (!language) {
      throw new Error(
        `Unknown language for {% highlight %}: ${lang}. Register it in eleventy.config.mjs.`
      );
    }

    const hl = await getHighlighter();
    const code = content.replace(/^\n+|\n+$/g, "");
    return hl.highlight(code, htmlInline({ language, theme }));
  });

  return {
    dir: {
      input: "src",
      includes: "_includes",
      layouts: "_includes/layouts",
      output: "_site",
    },
    templateFormats: ["njk", "md", "html"],
    htmlTemplateEngine: "njk",
    markdownTemplateEngine: "njk",
  };
}
