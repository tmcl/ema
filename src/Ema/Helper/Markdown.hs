{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Helper to deal with Markdown files
--
-- TODO: Publish this eventually to Hackage.
module Ema.Helper.Markdown
  ( -- Parsing
    -- TODO: Publish to Hackage as commonmark-pandoc-simple?
    parseMarkdownWithFrontMatter,
    parseMarkdown,
    fullMarkdownSpec,
    -- Utilities
    plainify,
    -- TODO: Publish to Hackage as commonmark-wikilink?
    wikilinkSpec,
    WikiLinkType (..),
  )
where

import qualified Commonmark as CM
import qualified Commonmark.Extensions as CE
import qualified Commonmark.Pandoc as CP
import qualified Commonmark.TokParsers as CT
import Control.Monad.Combinators (manyTill)
import Data.Aeson (FromJSON)
import qualified Data.Yaml as Y
import qualified Text.Megaparsec as M
import qualified Text.Megaparsec.Char as M
import qualified Text.Pandoc.Builder as B
import Text.Pandoc.Definition (Pandoc (..))
import qualified Text.Pandoc.Walk as W
import qualified Text.Parsec as P

-- | Parse a Markdown file using commonmark-hs with all extensions enabled
parseMarkdownWithFrontMatter ::
  forall meta m il bl.
  ( FromJSON meta,
    m ~ Either CM.ParseError,
    bl ~ CP.Cm () B.Blocks,
    il ~ CP.Cm () B.Inlines
  ) =>
  CM.SyntaxSpec m il bl ->
  -- | Path to file associated with this Markdown
  FilePath ->
  -- | Markdown text to parse
  Text ->
  Either Text (Maybe meta, Pandoc)
parseMarkdownWithFrontMatter spec fn s = do
  (mMeta, markdown) <- partitionMarkdown fn s
  mMetaVal <- first show $ (Y.decodeEither' . encodeUtf8) `traverse` mMeta
  blocks <- first show $ join $ CM.commonmarkWith @(Either CM.ParseError) spec fn markdown
  let doc = Pandoc mempty $ B.toList . CP.unCm @() @B.Blocks $ blocks
  pure (mMetaVal, doc)

parseMarkdown :: FilePath -> Text -> Either Text Pandoc
parseMarkdown fn s = do
  cmBlocks <- first show $ join $ CM.commonmarkWith @(Either CM.ParseError) fullMarkdownSpec fn s
  let blocks = B.toList . CP.unCm @() @B.Blocks $ cmBlocks
  pure $ Pandoc mempty blocks

type SyntaxSpec' m il bl =
  ( Monad m,
    CM.IsBlock il bl,
    CM.IsInline il,
    Typeable m,
    Typeable il,
    Typeable bl,
    CE.HasEmoji il,
    CE.HasStrikethrough il,
    CE.HasPipeTable il bl,
    CE.HasTaskList il bl,
    CM.ToPlainText il,
    CE.HasFootnote il bl,
    CE.HasMath il,
    CE.HasDefinitionList il bl,
    CE.HasDiv bl,
    CE.HasQuoted il,
    CE.HasSpan il
  )

-- | GFM + official commonmark extensions
fullMarkdownSpec ::
  SyntaxSpec' m il bl =>
  CM.SyntaxSpec m il bl
fullMarkdownSpec =
  mconcat
    [ CE.gfmExtensions,
      CE.fancyListSpec,
      CE.footnoteSpec,
      CE.mathSpec,
      CE.smartPunctuationSpec,
      CE.definitionListSpec,
      CE.attributesSpec,
      CE.rawAttributeSpec,
      CE.fencedDivSpec,
      CE.bracketedSpanSpec,
      CE.autolinkSpec,
      CM.defaultSyntaxSpec,
      -- as the commonmark documentation states, pipeTableSpec should be placed after
      -- fancyListSpec and defaultSyntaxSpec to avoid bad results when parsing
      -- non-table lines
      CE.pipeTableSpec
    ]

-- | Identify metadata block at the top, and split it from markdown body.
--
-- FIXME: https://github.com/srid/neuron/issues/175
partitionMarkdown :: FilePath -> Text -> Either Text (Maybe Text, Text)
partitionMarkdown =
  parse (M.try splitP <|> fmap (Nothing,) M.takeRest)
  where
    separatorP :: M.Parsec Void Text ()
    separatorP =
      void $ M.string "---" <* M.eol
    splitP :: M.Parsec Void Text (Maybe Text, Text)
    splitP = do
      separatorP
      a <- toText <$> manyTill M.anySingle (M.try $ M.eol *> separatorP)
      b <- M.takeRest
      pure (Just a, b)
    parse :: M.Parsec Void Text a -> String -> Text -> Either Text a
    parse p fn s =
      first (toText . M.errorBundlePretty) $
        M.parse (p <* M.eof) fn s

-- | Convert Pandoc AST inlines to raw text.
plainify :: [B.Inline] -> Text
plainify = W.query $ \case
  B.Str x -> x
  B.Code _attr x -> x
  B.Space -> " "
  B.SoftBreak -> " "
  B.LineBreak -> " "
  B.RawInline _fmt s -> s
  B.Math _mathTyp s -> s
  -- Ignore the rest of AST nodes, as they are recursively defined in terms of
  -- `Inline` which `W.query` will traverse again.
  _ -> ""

-- | A # prefix or suffix allows semantically distinct wikilinks
--
-- Typically called branching link or a tag link, when used with #.
data WikiLinkType
  = -- | [[Foo]]
    WikiLinkNormal
  | -- | [[Foo]]#
    WikiLinkBranch
  | -- | #[[Foo]]
    WikiLinkTag
  deriving (Eq, Show)

class HasWikiLink il where
  wikilink :: WikiLinkType -> Text -> il -> il

instance CM.Rangeable (CM.Html a) => HasWikiLink (CM.Html a) where
  wikilink typ url il =
    -- Store `typ` in link title, for later lookup.
    CM.link url (show typ) il

instance
  (HasWikiLink il, Semigroup il, Monoid il) =>
  HasWikiLink (CM.WithSourceMap il)
  where
  wikilink typ url il = (wikilink typ url <$> il) <* CM.addName "wikilink"

instance HasWikiLink (CP.Cm b B.Inlines) where
  wikilink typ t il = CP.Cm $ B.link t (show typ) $ CP.unCm il

-- | Like `Commonmark.Extensions.Wikilinks.wikilinkSpec` but Zettelkasten-friendly.
--
-- Compared with the official extension, this has two differences:
--
-- - Supports flipped inner text, eg: `[[Foo | some inner text]]`
-- - Supports neuron folgezettel, i.e.: #[[Foo]] or [[Foo]]#
wikilinkSpec ::
  (Monad m, CM.IsInline il, HasWikiLink il) =>
  CM.SyntaxSpec m il bl
wikilinkSpec =
  mempty
    { CM.syntaxInlineParsers =
        [ P.try $
            P.choice
              [ P.try (CT.symbol '#' *> pWikilink WikiLinkTag),
                P.try (pWikilink WikiLinkBranch <* CT.symbol '#'),
                P.try (pWikilink WikiLinkNormal)
              ]
        ]
    }
  where
    pWikilink typ = do
      replicateM_ 2 $ CT.symbol '['
      P.notFollowedBy (CT.symbol '[')
      url <-
        CM.untokenize
          <$> many
            ( CT.satisfyTok
                ( \t ->
                    not (CT.hasType (CM.Symbol '|') t || CT.hasType (CM.Symbol ']') t)
                )
            )
      title <-
        M.option url $
          CM.untokenize
            <$> ( CT.symbol '|'
                    *> many (CT.satisfyTok (not . CT.hasType (CM.Symbol ']')))
                )
      replicateM_ 2 $ CT.symbol ']'
      return $ wikilink typ url (CM.str title)
