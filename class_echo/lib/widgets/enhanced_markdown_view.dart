import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

class EnhancedMarkdownView extends StatelessWidget {
  final String data;
  final bool selectable;
  final Map<String, TextStyle>? highlightTheme;

  const EnhancedMarkdownView({
    super.key,
    required this.data,
    this.selectable = true,
    this.highlightTheme,
  });

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      selectable: selectable,
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(color: Colors.white70, height: 1.55),
        h1: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        h2: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
        h3: const TextStyle(
          color: Colors.cyanAccent,
          fontWeight: FontWeight.w600,
        ),
        code: const TextStyle(color: Colors.cyanAccent),
        codeblockDecoration: BoxDecoration(
          color: const Color(0xFF121A2A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        blockquoteDecoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white10),
        ),
      ),
      builders: {
        'pre': CodeBlockBuilder(theme: highlightTheme ?? atomOneDarkTheme),
        'inline_math': InlineMathBuilder(),
        'block_math': BlockMathBuilder(),
      },
      inlineSyntaxes: [InlineMathSyntax()],
      blockSyntaxes: [BlockMathSyntax()],
    );
  }
}

class CodeBlockBuilder extends MarkdownElementBuilder {
  final Map<String, TextStyle> theme;

  CodeBlockBuilder({required this.theme});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final codeElement = element.children?.firstWhere(
      (node) => node is md.Element && node.tag == 'code',
      orElse: () => md.Element.text('code', element.textContent),
    );

    String code = element.textContent;
    String language = 'plaintext';

    if (codeElement is md.Element) {
      code = codeElement.textContent;
      final className = codeElement.attributes['class'] ?? '';
      final match = RegExp(
        r'language-([a-zA-Z0-9_+#-]+)',
      ).firstMatch(className);
      if (match != null) {
        language = _normalizeLanguage(match.group(1)!);
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF121A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: HighlightView(
                code.trimRight(),
                language: language,
                theme: theme,
                tabSize: 2,
                textStyle: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
          ),
          Positioned(top: 6, right: 6, child: _CopyCodeButton(code: code)),
        ],
      ),
    );
  }

  String _normalizeLanguage(String raw) {
    final lang = raw.toLowerCase();
    switch (lang) {
      case 'c++':
      case 'cpp':
      case 'cc':
      case 'cxx':
        return 'cpp';
      case 'c':
        return 'c';
      case 'py':
      case 'python':
        return 'python';
      default:
        return lang;
    }
  }
}

class _CopyCodeButton extends StatelessWidget {
  final String code;

  const _CopyCodeButton({required this.code});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: code));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('代码已复制'),
              duration: Duration(milliseconds: 900),
            ),
          );
        },
        child: const Padding(
          padding: EdgeInsets.all(6),
          child: Icon(Icons.copy, size: 16, color: Colors.white70),
        ),
      ),
    );
  }
}

class InlineMathSyntax extends md.InlineSyntax {
  InlineMathSyntax() : super(r'(?<!\\)\$([^\n\$]+?)\$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final expression = match.group(1);
    if (expression == null || expression.trim().isEmpty) {
      return false;
    }
    parser.addNode(md.Element.text('inline_math', expression));
    return true;
  }
}

class BlockMathSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(r'^\s*\$\$');

  @override
  bool canParse(md.BlockParser parser) =>
      pattern.hasMatch(parser.current.content);

  @override
  md.Node parse(md.BlockParser parser) {
    final first = parser.current.content.trim();

    if (first.startsWith(r'$$') && first.endsWith(r'$$') && first.length > 4) {
      final singleLine = first.substring(2, first.length - 2).trim();
      parser.advance();
      return md.Element.text('block_math', singleLine);
    }

    parser.advance();
    final lines = <String>[];
    while (!parser.isDone) {
      final line = parser.current.content;
      if (line.trim() == r'$$') {
        parser.advance();
        break;
      }
      lines.add(line);
      parser.advance();
    }

    return md.Element.text('block_math', lines.join('\n').trim());
  }
}

class InlineMathBuilder extends MarkdownElementBuilder {
  InlineMathBuilder();

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final expression = element.textContent.trim();
    if (expression.isEmpty) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Math.tex(
        expression,
        mathStyle: MathStyle.text,
        textStyle: preferredStyle ?? const TextStyle(color: Colors.white),
      ),
    );
  }
}

class BlockMathBuilder extends MarkdownElementBuilder {
  BlockMathBuilder();

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final expression = element.textContent.trim();
    if (expression.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Math.tex(
          expression,
          mathStyle: MathStyle.display,
          textStyle: preferredStyle ?? const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}
