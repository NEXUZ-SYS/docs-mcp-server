import { describe, expect, it } from "vitest";
import { isLlmsTxtUrl, parseLlmsTxt } from "./llmsTxtParser";

describe("parseLlmsTxt", () => {
  it("parses llms.txt without an H1 (bare title line + ## sections, e.g. ai.google.dev)", () => {
    const result = parseLlmsTxt(`Gemini API Docs and API Reference

## Docs

- [Quickstart](https://ai.google.dev/gemini-api/docs/quickstart.md.txt): Get started
- [Text generation](https://ai.google.dev/gemini-api/docs/text-generation.md.txt): Generate text
`);

    expect(result.links.map((l) => l.url)).toEqual([
      "https://ai.google.dev/gemini-api/docs/quickstart.md.txt",
      "https://ai.google.dev/gemini-api/docs/text-generation.md.txt",
    ]);
    expect(result.sections).toHaveLength(1);
    expect(result.sections[0].title).toBe("Docs");
    expect(result.projectName).toBe("Gemini API Docs and API Reference");
  });

  it("still rejects HTML and link-less content masquerading as llms.txt", () => {
    expect(
      parseLlmsTxt("<!doctype html><html><body>nope</body></html>").links,
    ).toHaveLength(0);
    expect(parseLlmsTxt("just some prose with no links at all").links).toHaveLength(0);
  });

  it("parses complete llms.txt content with sections and summary", () => {
    const result = parseLlmsTxt(`# Example Docs

> Official documentation for Example.
> Includes guides and API references.

## Guides

- [Getting Started](https://example.com/docs/start): Start here
- [Install](/docs/install)

## Optional

- [Changelog](https://example.com/changelog): Release notes
`);

    expect(result.projectName).toBe("Example Docs");
    expect(result.summary).toBe(
      "Official documentation for Example.\nIncludes guides and API references.",
    );
    expect(result.sections).toHaveLength(2);
    expect(result.sections[0]).toMatchObject({
      title: "Guides",
      optional: false,
    });
    expect(result.sections[1]).toMatchObject({
      title: "Optional",
      optional: true,
    });
    expect(result.links).toEqual([
      {
        title: "Getting Started",
        url: "https://example.com/docs/start",
        description: "Start here",
        optional: false,
        section: "Guides",
      },
      {
        title: "Install",
        url: "/docs/install",
        optional: false,
        section: "Guides",
      },
      {
        title: "Changelog",
        url: "https://example.com/changelog",
        description: "Release notes",
        optional: true,
        section: "Optional",
      },
    ]);
  });

  it("parses minimal llms.txt content", () => {
    const result = parseLlmsTxt(`# Minimal

- [Home](guide/intro)
`);

    expect(result.projectName).toBe("Minimal");
    expect(result.summary).toBeUndefined();
    expect(result.sections).toEqual([]);
    expect(result.links).toEqual([
      {
        title: "Home",
        url: "guide/intro",
        optional: false,
      },
    ]);
  });

  it("supports links with and without descriptions", () => {
    const result = parseLlmsTxt(`# Links

- [Described](https://example.com/a): Useful page
- [Plain](https://example.com/b)
`);

    expect(result.links[0]?.description).toBe("Useful page");
    expect(result.links[1]?.description).toBeUndefined();
  });

  it("returns an empty result for empty or invalid content", () => {
    expect(parseLlmsTxt("")).toEqual({ sections: [], links: [] });
    // No-H1 docs WITH links are now accepted (bare title + link list, e.g. ai.google.dev):
    // the first content line becomes the project name and the links are parsed.
    expect(parseLlmsTxt("No heading\n- [Link](https://example.com)").links).toEqual([
      { title: "Link", url: "https://example.com", optional: false },
    ]);
    expect(parseLlmsTxt("# Project\n\nNo links")).toEqual({ sections: [], links: [] });
  });

  it("returns an empty result for HTML and binary-like content", () => {
    expect(parseLlmsTxt("<!doctype html><html><body>nope</body></html>")).toEqual({
      sections: [],
      links: [],
    });
    expect(parseLlmsTxt("# Project\n\0\n- [Link](https://example.com)")).toEqual({
      sections: [],
      links: [],
    });
  });

  it("ignores multiple H1s and malformed links", () => {
    const result = parseLlmsTxt(`# First

# Second

- [Good](https://example.com/good)
- [Missing close paren](https://example.com/bad
- Missing brackets (https://example.com/bad)
`);

    expect(result.projectName).toBe("First");
    expect(result.links).toEqual([
      {
        title: "Good",
        url: "https://example.com/good",
        optional: false,
      },
    ]);
  });
});

describe("isLlmsTxtUrl", () => {
  it("matches URLs whose path basename is llms.txt", () => {
    expect(isLlmsTxtUrl("https://example.com/llms.txt")).toBe(true);
    expect(isLlmsTxtUrl("https://example.com/docs/LLMS.TXT?cache=1#top")).toBe(true);
  });

  it("does not match non-llms.txt URLs", () => {
    expect(isLlmsTxtUrl("https://example.com/docs/llms.txt/child")).toBe(false);
    expect(isLlmsTxtUrl("https://example.com/docs/llms-full.txt")).toBe(false);
    expect(isLlmsTxtUrl("not a url")).toBe(false);
  });
});
