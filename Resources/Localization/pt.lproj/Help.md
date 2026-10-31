---
title: Guia de Markdown
subtitle: Tudo o que o Z-MarkDowner pode fazer
---

Abra a **visualização dividida** (⌘2) para ver o código-fonte e o resultado lado a lado.

## Formatação de texto

- **Negrito** – `**texto**` (⌘B)
- *Itálico* – `*texto*` (⌘I)
- ~~Tachado~~ – `~~texto~~` (⇧⌘X)
- `Código` – `` `código` `` (⌘`)
- [Link](https://pt.wikipedia.org/wiki/Markdown) – `[texto](endereço)` (⌘K)

## Títulos

`# Título 1` … `###### Título 6` (⌥⌘1 … ⌥⌘6). A **barra lateral** (⌃⌘S) os exibe como uma estrutura.

## Listas

1. Lista numerada (⇧⌘7)
2. Segundo item
    - Item aninhado (recue com Tab)

- [x] Concluído
- [ ] A fazer (⇧⌘9)

> Citação (⇧⌘')

## Tabelas

| Recurso | Atalho |
|:--------|:--------:|
| Editor | ⌘1 |
| Visualização dividida | ⌘2 |
| Visualização final | ⌘3 |
| Tela cheia | ⌃⌘F |

Dentro de uma tabela, **Tab** pula para a próxima célula e alinha as colunas; **Return** adiciona uma linha.

## Código

```swift
func greet(_ name: String) -> String {
    return "Olá, \(name)!"   // realce de sintaxe
}
```

## Notas de rodapé

O Markdown suporta notas de rodapé[^1].

[^1]: O texto da nota aparece no final do documento — e como uma nota de rodapé real no Word.

## Fórmulas e diagramas

Em linha: $e^{i\pi} + 1 = 0$

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

```mermaid
graph LR
    A[Markdown] --> B[PDF]
    A --> C[Word]
    A --> D[EPUB]
```

## Imagens

Cole uma captura de tela (⌘V) ou arraste uma imagem para o editor: ela é salva em uma pasta `images` ao lado do documento.

## Citações e referências

Indique um arquivo BibTeX (`.bib`) ou CSL-JSON no front matter (ou defina um padrão em Ajustes ▸ Escrita) e cite com `[@key]`:

```markdown
---
bibliography: references.bib
csl: vancouver        # ou apa
---

As shown earlier [@kovacs2020, p. 5; @who2019], … @kovacs2020 found …
```

A lista de referências é adicionada no final (ou onde você colocar `::: {#refs}` … `:::`). **Formatar ▸ Citações e Referências ▸ Inserir Citação…** (⌃⌘C) busca na bibliografia e adiciona novas referências por **DOI ou ID do PubMed**. Ao digitar `@`, as chaves são sugeridas.

## Figuras, tabelas numeradas e referências cruzadas

| Formato | Resultado |
|---------|-----------|
| PDF     | sumário com números de página |
| Word    | sumário real do Word, legendas |

Table: Exportações {#tbl:exports}

@tbl:exports lista os formatos de saída. Rotule figuras com `![Caption](image.png){#fig:name}`, equações com `$$ … $$ {#eq:name}`, cabeçalhos com `# Title {#sec:name}` e faça referência a eles com `@fig:name`, `@eq:name`, `@sec:name`. `[TOC]` (ou `toc: true` no front matter) insere um sumário; `numbersections: true` numera os cabeçalhos.

## Revisão: alterações e comentários

As alterações controladas e os comentários de documentos do Word são importados como marcas de revisão — e exportados de volta para o Word como alterações controladas e comentários: {++inserido++}, {--apagado--}, {~~antigo~>novo~~}, {==destacado==}{>>Um comentário<<}. Use **Editar ▸ Revisão** para aceitá-los ou rejeitá-los.

## Formatação ao vivo e ferramentas de escrita

**Visualizar ▸ Formatação ao Vivo** (⌥⌘L) oculta as marcações Markdown, exceto na linha que você está editando. Clique na contagem de palavras na barra de status para ver estatísticas, tempo de leitura e metas de escrita. A aba **Buscar** da barra lateral busca e substitui em todos os arquivos Markdown e de texto de uma pasta (⌥⇧⌘F).

---

**Exportar:** Arquivo ▸ Exportar ▸ PDF (⇧⌘E), Word (⇧⌘D), HTML ou EPUB.
**Importar:** Arquivo ▸ Abrir (⌘O) – arquivos DOCX, DOC, RTF, TXT e MD.
