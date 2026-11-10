/**
 * Turns GitHub alert blockquotes (`> [!NOTE]`, `> [!TIP]`, ...) into Starlight asides, so docs
 * can use the one callout syntax that also renders on GitHub.
 *
 * The plugin builds the finished aside itself (the markup of Starlight's `remarkAsides`), because
 * Starlight registers its own aside transform ahead of the user's `markdown.remarkPlugins`: a
 * `containerDirective` produced here reached the page as a bare `<div>`. The label is the one
 * GitHub shows for the alert, so a callout reads the same on both; the class picks one of
 * Starlight's four aside styles (themed in src/styles/docs.css).
 */
import { visit } from "unist-util-visit";

const TYPES = {
  NOTE: { variant: "note", label: "Note" },
  TIP: { variant: "tip", label: "Tip" },
  IMPORTANT: { variant: "note", label: "Important" },
  WARNING: { variant: "caution", label: "Warning" },
  CAUTION: { variant: "danger", label: "Caution" }
};
const MARKER = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(?:\r?\n|$)/;

/** An mdast node that remark-rehype turns into the given HTML element. */
const element = (tagName, properties, children) => ({
  type: "paragraph",
  data: { hName: tagName, hProperties: properties },
  children
});

export default function remarkGithubAlerts() {
  return (tree) => {
    visit(tree, "blockquote", (node, index, parent) => {
      const paragraph = node.children[0];
      const first = paragraph?.type === "paragraph" ? paragraph.children[0] : undefined;
      if (!parent || index === undefined || first?.type !== "text") return;
      const match = MARKER.exec(first.value);
      if (!match) return;
      first.value = first.value.slice(match[0].length);
      if (first.value === "") paragraph.children.shift();
      if (paragraph.children.length === 0) node.children.shift();
      const { variant, label } = TYPES[match[1]];
      parent.children[index] = element(
        "aside",
        { ariaLabel: label, className: ["starlight-aside", `starlight-aside--${variant}`] },
        [
          element("p", { className: ["starlight-aside__title"], ariaHidden: "true" }, [
            { type: "text", value: label }
          ]),
          element("div", { className: ["starlight-aside__content"] }, node.children)
        ]
      );
      return "skip";
    });
  };
}
