{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}
{- |
   Module      : Text.Pandoc.Writers.JATS
   Copyright   : 2017-2024 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of 'Pandoc' documents to JATS XML.
Reference:
https://jats.nlm.nih.gov/publishing/tag-library
-}
module Text.Pandoc.Writers.JATS
  ( writeJATS
  , writeJatsArchiving
  , writeJatsPublishing
  , writeJatsArticleAuthoring
  ) where
import Control.Applicative ((<|>))
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Data.Generics (everywhere, mkT)
import qualified Data.Map as M
import Data.Maybe (fromMaybe, listToMaybe, isNothing)
import Data.Time (toGregorian, Day, parseTimeM, defaultTimeLocale, formatTime)
import qualified Data.Text as T
import Data.Text (Text)
import Text.Pandoc.Citeproc (getReferences)
import Text.Pandoc.Class.PandocMonad (PandocMonad, report)
import Text.Pandoc.Definition
import Text.Pandoc.Highlighting (languages, languagesByExtension)
import Text.Pandoc.Logging
import Text.Pandoc.MIME (getMimeType)
import Text.Pandoc.Walk (walk)
import Text.Pandoc.Options
import Text.DocLayout
import Text.Pandoc.Shared
import Text.Pandoc.URI
import Text.Pandoc.Templates (renderTemplate)
import Text.DocTemplates (Context(..), Val(..), toVal)
import Text.Pandoc.Writers.JATS.References (referencesToJATS)
import Text.Pandoc.Writers.JATS.Table (tableToJATS)
import Text.Pandoc.Writers.JATS.Types
import Text.Pandoc.Writers.Math
import Text.Pandoc.Writers.Shared
import Text.Pandoc.XML
import Text.TeXMath
import qualified Text.Pandoc.Writers.AnnotatedTable as Ann
import qualified Text.XML.Light as Xml

-- | Default human-readable names for roles in the Contributor Role
-- Taxonomy (CRediT). This is useful for generating JATS that annotate
-- contributor roles
creditNames :: M.Map Text Text
creditNames = M.fromList [
    ("conceptualization", "Conceptualization"),
    ("data-curation", "Data curation"),
    ("formal-analysis", "Formal analysis"),
    ("funding-acquisition", "Funding acquisition"),
    ("investigation", "Investigation"),
    ("methodology", "Methodology"),
    ("project-administration", "Project administration"),
    ("resources", "Resources"),
    ("software", "Software"),
    ("supervision", "Supervision"),
    ("validation", "Validation"),
    ("visualization", "Visualization"),
    ("writing-original-draft", "Writing – original draft"),
    ("writing-review-editing", "Writing – review &amp; editing")]

-- | Ensure every role with a `credit` key also has a `credit-name`,
-- using a default value if necessary
addCreditNames :: Context Text -> Context Text
addCreditNames context =
  case getField "author" context of
    -- If there is an "authors" key, then we replace the existing value
    -- with one we mutate by running the addCreditNamesToAuthor helper
    -- function on each
    Just (ListVal authors) ->
      resetField "author" (map addCreditNamesToAuthor authors) context
    -- If there is no "authors" key in the context, then we don't have to do
    -- anything, and just return the context as is
    _ -> context
  where
    addCreditNamesToAuthor :: Val Text -> Val Text
    addCreditNamesToAuthor val = fromMaybe val $ do
      MapVal authorCtx <- pure val
      ListVal roles <- getField "roles" authorCtx
      return $ toVal $ resetField "roles" (map addCreditNameToRole roles) authorCtx

    addCreditNameToRole :: Val Text -> Val Text
    addCreditNameToRole val = fromMaybe val $ do
      MapVal roleCtx <- pure val
      guard $ isNothing (getField "credit-name" roleCtx :: Maybe (Val Text))
      creditId <- getField "credit" roleCtx
      creditName <- M.lookup creditId creditNames
      return $ toVal $ resetField "credit-name" creditName roleCtx

-- | Convert a @'Pandoc'@ document to JATS (Archiving and Interchange
-- Tag Set.)
writeJatsArchiving :: PandocMonad m => WriterOptions -> Pandoc -> m Text
writeJatsArchiving = writeJats TagSetArchiving

-- | Convert a @'Pandoc'@ document to JATS (Journal Publishing Tag Set.)
writeJatsPublishing :: PandocMonad m => WriterOptions -> Pandoc -> m Text
writeJatsPublishing = writeJats TagSetPublishing

-- | Convert a @'Pandoc'@ document to JATS (Archiving and Interchange
-- Tag Set.)
writeJatsArticleAuthoring :: PandocMonad m => WriterOptions -> Pandoc -> m Text
writeJatsArticleAuthoring = writeJats TagSetArticleAuthoring

-- | Alias for @'writeJatsArchiving'@. This function exists for backwards
-- compatibility, but will be deprecated in the future. Use
-- @'writeJatsArchiving'@ instead.
{-# DEPRECATED writeJATS "Use writeJatsArchiving instead" #-}
writeJATS :: PandocMonad m => WriterOptions -> Pandoc -> m Text
writeJATS = writeJatsArchiving

-- | Convert a @'Pandoc'@ document to JATS.
writeJats :: PandocMonad m => JATSTagSet -> WriterOptions -> Pandoc -> m Text
writeJats tagSet opts d = do
  refs <- if extensionEnabled Ext_element_citations $ writerExtensions opts
          then getReferences Nothing d
          else pure []
  let environment = JATSEnv
          { jatsTagSet = tagSet
          , jatsInlinesWriter = inlinesToJATS
          , jatsBlockWriter = wrappedBlocksToJATS
          , jatsReferences = refs
          }
  let initialState = JATSState { jatsNotes = [] }
  runReaderT (evalStateT (docToJATS opts d) initialState)
             environment

-- see #9017 for motivation
ensureReferenceHeader :: [Block] -> [Block]
ensureReferenceHeader [] = []
ensureReferenceHeader (h@(Header{}):refs@(Div ("refs",_,_) _) : xs) =
  h:refs:xs
ensureReferenceHeader (refs@(Div ("refs",_,_) _) : xs) =
  Header 1 nullAttr mempty : refs : xs
ensureReferenceHeader (x:xs) = x :ensureReferenceHeader xs

-- | Convert Pandoc document to string in JATS format.
docToJATS :: PandocMonad m => WriterOptions -> Pandoc -> JATS m Text
docToJATS opts (Pandoc meta blocks') = do
  -- The numbering here follows LaTeX's internal numbering
  let startLvl = case writerTopLevelDivision opts of
                   TopLevelPart    -> -1
                   TopLevelChapter -> 0
                   TopLevelSection -> 1
                   TopLevelDefault -> 1
  let blocks = makeSections (writerNumberSections opts) (Just startLvl)
                  $ ensureReferenceHeader blocks'
  let splitBackBlocks b@(Div ("refs",_,_) _) (fs, bs) = (fs, b:bs)
      splitBackBlocks (Div (ident,("section":_),_)
                               ( Header lev (_,hcls,hkvs) hils
                               : (Div rattrs@("refs",_,_) rs)
                               : rest
                               )) (fs, bs)
                       = (fs ++ rest,
                            Div rattrs
                             (Header lev (ident,hcls,hkvs) hils : rs) : bs)
      splitBackBlocks b (fs, bs) = (b:fs, bs)
  let (bodyblocks, backblocks) = foldr splitBackBlocks ([],[]) blocks
  let colwidth = if writerWrapText opts == WrapAuto
                    then Just $ writerColumns opts
                    else Nothing
  metadata <- metaToContext opts
                 (blocksToJATS opts . makeSections False (Just startLvl))
                 (fmap chomp . inlinesToJATS opts)
                 meta
  main <- blocksToJATS opts bodyblocks
  notes <- gets (reverse . map snd . jatsNotes)
  backs <- blocksToJATS opts backblocks
  tagSet <- asks jatsTagSet
  -- In the "Article Authoring" tag set, occurrence of fn-group elements
  -- is restricted to table footers. Footnotes have to be placed inline.
  let fns = if null notes || tagSet == TagSetArticleAuthoring
            then mempty
            else inTagsIndented "fn-group" $ vcat notes
  let back = backs $$ fns
  let date =
        case getField "date" metadata of
          Nothing -> NullVal
          Just (SimpleVal (x :: Doc Text)) ->
             case parseDate (render Nothing x) of
               Nothing  -> NullVal
               Just day ->
                 let (y,m,d) = toGregorian day
                 in  MapVal . Context $ M.fromList
                      [("year" :: Text, SimpleVal $ text $ show y)
                      ,("month", SimpleVal $ text $ show m)
                      ,("day", SimpleVal $ text $ show d)
                      ,("iso-8601", SimpleVal $ text $
                            formatTime defaultTimeLocale "%F" day)
                      ]
          Just x -> x
  title' <- inlinesToJATS opts $ map fixLineBreak
               (lookupMetaInlines "title" meta)
  let context = defField "body" main
              $ defField "back" back
              $ addCreditNames
              $ resetField "title" title'
              $ resetField "date" date
              $ defField "mathml" (case writerHTMLMathMethod opts of
                                        MathML -> True
                                        _      -> False) metadata
  return $ render colwidth $
    (if writerPreferAscii opts then fmap toEntities else id) $
    case writerTemplate opts of
       Nothing  -> main
       Just tpl -> renderTemplate tpl context

-- | Convert a list of Pandoc blocks to JATS.
blocksToJATS :: PandocMonad m => WriterOptions -> [Block] -> JATS m (Doc Text)
blocksToJATS = wrappedBlocksToJATS (const False)

-- | Like @'blocksToJATS'@, but wraps top-level blocks into a @<p>@
-- element if the @needsWrap@ predicate evaluates to @True@.
wrappedBlocksToJATS :: PandocMonad m
                    => (Block -> Bool)
                    -> WriterOptions
                    -> [Block]
                    -> JATS m (Doc Text)
wrappedBlocksToJATS needsWrap opts =
  fmap vcat . mapM wrappedBlockToJATS
  where
    wrappedBlockToJATS b = do
      inner <- blockToJATS opts b
      return $
        if needsWrap b
           then inTags True "p" [("specific-use","wrapper")] inner
           else inner

-- | Auxiliary function to convert Plain block to Para.
plainToPara :: Block -> Block
plainToPara (Plain x) = Para x
plainToPara x         = x

-- | Convert a list of pairs of terms and definitions into a list of
-- JATS varlistentrys.
deflistItemsToJATS :: PandocMonad m
                   => WriterOptions
                   -> [([Inline],[[Block]])] -> JATS m (Doc Text)
deflistItemsToJATS opts items =
  vcat <$> mapM (uncurry (deflistItemToJATS opts)) items

-- | Convert a term and a list of blocks into a JATS varlistentry.
deflistItemToJATS :: PandocMonad m
                  => WriterOptions
                  -> [Inline] -> [[Block]] -> JATS m (Doc Text)
deflistItemToJATS opts term defs = do
  term' <- inlinesToJATS opts term
  def' <- wrappedBlocksToJATS (not . isPara)
              opts $ concatMap (walk demoteHeaderAndRefs .
                                map plainToPara) defs
  return $ inTagsIndented "def-item" $
      inTagsSimple "term" term' $$
      inTagsIndented "def" def'

-- | Convert a list of lists of blocks to a list of JATS list items.
listItemsToJATS :: PandocMonad m
                => WriterOptions
                -> Maybe [Text] -> [[Block]] -> JATS m (Doc Text)
listItemsToJATS opts markers items =
  case markers of
       Nothing -> vcat <$> mapM (listItemToJATS opts Nothing) items
       Just ms -> vcat <$> zipWithM (listItemToJATS opts) (map Just ms) items

-- | Convert a list of blocks into a JATS list item.
listItemToJATS :: PandocMonad m
               => WriterOptions
               -> Maybe Text -> [Block] -> JATS m (Doc Text)
listItemToJATS opts mbmarker item = do
  contents <- wrappedBlocksToJATS (not . isParaOrList) opts
                 (walk demoteHeaderAndRefs item)
  return $ inTagsIndented "list-item" $
           maybe empty (inTagsSimple "label" . text . T.unpack) mbmarker
           $$ contents

languageFor :: WriterOptions -> [Text] -> Text
languageFor opts classes =
  case langs of
     (l:_) -> escapeStringForXML l
     []    -> ""
    where
          syntaxMap = writerSyntaxMap opts
          isLang l    = T.toLower l `elem` map T.toLower (languages syntaxMap)
          langsFrom s = if isLang s
                           then [s]
                           else (languagesByExtension syntaxMap) . T.toLower $ s
          langs       = concatMap langsFrom classes

codeAttr :: WriterOptions -> Attr -> (Text, [(Text, Text)])
codeAttr opts (ident,classes,kvs) = (lang, attr)
    where
       attr = [("id", escapeNCName ident) | not (T.null ident)] ++
              [("language",lang) | not (T.null lang)] ++
              [(k,v) | (k,v) <- kvs, k `elem` ["code-type",
                "code-version", "executable",
                "language-version", "orientation",
                    "platforms", "position", "specific-use"]]
       lang  = languageFor opts classes

-- <break/> is only allowed as a direct child of <td> or <title> or
-- <article-title>
fixLineBreak :: Inline -> Inline
fixLineBreak LineBreak = RawInline (Format "jats") "<break/>"
fixLineBreak x = x

-- | Convert a Pandoc block element to JATS.
blockToJATS :: PandocMonad m => WriterOptions -> Block -> JATS m (Doc Text)
blockToJATS opts (Div (id',"section":_,kvs) (Header _lvl (_,_,hkvs) ils : xs)) = do
  let idAttr = [ ("id", writerIdentifierPrefix opts <> escapeNCName id')
               | not (T.null id')]
  let otherAttrs = ["sec-type", "specific-use"]
  let attribs = idAttr ++ [(k,v) | (k,v) <- kvs, k `elem` otherAttrs]
  title' <- inlinesToJATS opts (map fixLineBreak ils)
  let label = if writerNumberSections opts
                 then
                   case lookup "number" hkvs of
                     Just num -> inTagsSimple "label" (literal num)
                     Nothing -> mempty
                 else mempty
  contents <- blocksToJATS opts xs
  return $ inTags True "sec" attribs $
      label $$
      inTagsSimple "title" title' $$ contents
-- Bibliography reference:
blockToJATS opts (Div (ident,_,_) [Para lst]) | "ref-" `T.isPrefixOf` ident =
  inTags True "ref" [("id", escapeNCName ident)] .
  inTagsSimple "mixed-citation" <$>
  inlinesToJATS opts lst
blockToJATS opts (Div ("refs",_,_) xs) = do
  refs <- asks jatsReferences
  contents <- if null refs
              then blocksToJATS opts xs
              else do
                titleElement <- case xs of
                  (Header _ _ title:_) ->
                    inTagsSimple "title" <$> inlinesToJATS opts title
                  _ -> return mempty
                elementRefs <- referencesToJATS opts refs
                return $ titleElement $$ elementRefs
  return $ inTagsIndented "ref-list" contents
blockToJATS opts (Div (ident,[cls],kvs) bs) | cls `elem` ["fig", "caption", "table-wrap"] = do
  contents <- blocksToJATS opts bs
  let attr = [("id", escapeNCName ident) | not (T.null ident)] ++
             [("xml:lang",l) | ("lang",l) <- kvs] ++
             [(k,v) | (k,v) <- kvs, k `elem` ["specific-use",
                 "content-type", "orientation", "position"]]
  return $ inTags True cls attr contents
blockToJATS opts (Div (ident,_,kvs) bs) = do
  contents <- blocksToJATS opts bs
  let attr = [("id", escapeNCName ident) | not (T.null ident)] ++
             [("xml:lang",l) | ("lang",l) <- kvs] ++
             [(k,v) | (k,v) <- kvs, k `elem` ["specific-use",
                 "content-type", "orientation", "position"]]
  return $ inTags True "boxed-text" attr contents
blockToJATS opts (Header _ _ title) = do
  title' <- inlinesToJATS opts (map fixLineBreak title)
  return $ inTagsSimple "title" title'
-- Special cases for bare images, which are rendered as graphics
blockToJATS _opts (Plain [Image attr alt tgt]) =
  return $ graphic attr alt tgt
blockToJATS _opts (Para [Image attr alt tgt]) =
  return $ graphic attr alt tgt
-- No Plain, everything needs to be in a block-level tag
blockToJATS opts (Plain lst) = blockToJATS opts (Para lst)
blockToJATS opts (Para lst) =
  inTagsSimple "p" <$> inlinesToJATS opts lst
blockToJATS opts (LineBlock lns) =
  blockToJATS opts $ linesToPara lns
blockToJATS opts (BlockQuote blocks) = do
  tagSet <- asks jatsTagSet
  let needsWrap = if tagSet == TagSetArticleAuthoring
                  then not . isPara
                  else \case
                    Header{}       -> True
                    HorizontalRule -> True
                    _              -> False
  inTagsIndented "disp-quote" <$> wrappedBlocksToJATS needsWrap opts blocks
blockToJATS opts (CodeBlock a str) = return $
  inTags False tag attr (flush (text (T.unpack $ escapeStringForXML str)))
    where (lang, attr) = codeAttr opts a
          tag          = if T.null lang then "preformat" else "code"
blockToJATS _ (BulletList []) = return empty
blockToJATS opts (BulletList lst) =
  inTags True "list" [("list-type", "bullet")] <$>
  listItemsToJATS opts Nothing lst
blockToJATS _ (OrderedList _ []) = return empty
blockToJATS opts (OrderedList (start, numstyle, delimstyle) items) = do
  tagSet <- asks jatsTagSet
  let listType =
        -- The Article Authoring tag set doesn't allow a more specific
        -- @list-type@ attribute than "order".
        if tagSet == TagSetArticleAuthoring
        then "order"
        else case numstyle of
               DefaultStyle -> "order"
               Decimal      -> "order"
               Example      -> "order"
               UpperAlpha   -> "alpha-upper"
               LowerAlpha   -> "alpha-lower"
               UpperRoman   -> "roman-upper"
               LowerRoman   -> "roman-lower"
  let simpleList = start == 1 && (delimstyle == DefaultDelim ||
                                  delimstyle == Period)
  let markers = if simpleList
                   then Nothing
                   else Just $
                          orderedListMarkers (start, numstyle, delimstyle)
  inTags True "list" [("list-type", listType)] <$>
    listItemsToJATS opts markers items
blockToJATS opts (DefinitionList lst) =
  inTags True "def-list" [] <$> deflistItemsToJATS opts lst
blockToJATS _ b@(RawBlock f str)
  | f == "jats"    = return $ text $ T.unpack str -- raw XML block
  | otherwise      = do
      report $ BlockNotRendered b
      return empty
blockToJATS _ HorizontalRule = return empty -- not semantic
blockToJATS opts (Table attr caption colspecs thead tbody tfoot) =
  tableToJATS opts (Ann.toTable attr caption colspecs thead tbody tfoot)
blockToJATS opts (Figure (ident, _, kvs) (Caption _short longcapt) body) = do
  -- Remove the alt text from images if it's the same as the caption text.
  let unsetAltIfDupl = \case
        Image attr alt tgt
          | stringify alt == stringify longcapt -> Image attr [] tgt
        inline -> inline
  capt <- if null longcapt
          then pure empty
          else inTagsSimple "caption" <$> blocksToJATS opts longcapt
  figbod <- blocksToJATS opts $ walk unsetAltIfDupl body
  let figattr = [("id", escapeNCName ident) | not (T.null ident)] ++
                [(k,v) | (k,v) <- kvs
                       , k `elem` [ "fig-type", "orientation"
                                  , "position", "specific-use"]]
  return $ inTags True "fig" figattr $ capt $$ figbod

-- | Convert a list of inline elements to JATS.
inlinesToJATS :: PandocMonad m => WriterOptions -> [Inline] -> JATS m (Doc Text)
inlinesToJATS opts lst = hcat <$> mapM (inlineToJATS opts) (fixCitations lst)
  where
   fixCitations [] = []
   fixCitations (x:xs) | needsFixing x =
     x : Str (stringify ys) : fixCitations zs
     where
       needsFixing (RawInline (Format "jats") z) =
           "<pub-id pub-id-type=" `T.isPrefixOf` z
       needsFixing _           = False
       isRawInline RawInline{} = True
       isRawInline _           = False
       (ys,zs)                 = break isRawInline xs
   fixCitations (x:xs) = x : fixCitations xs

-- | Convert an inline element to JATS.
inlineToJATS :: PandocMonad m => WriterOptions -> Inline -> JATS m (Doc Text)
inlineToJATS _ (Str str) = return $ text $ T.unpack $ escapeStringForXML str
inlineToJATS opts (Emph lst) =
  inTagsSimple "italic" <$> inlinesToJATS opts lst
inlineToJATS opts (Underline lst) =
  inTagsSimple "underline" <$> inlinesToJATS opts lst
inlineToJATS opts (Strong lst) =
  inTagsSimple "bold" <$> inlinesToJATS opts lst
inlineToJATS opts (Strikeout lst) =
  inTagsSimple "strike" <$> inlinesToJATS opts lst
inlineToJATS opts (Superscript lst) =
  inTagsSimple "sup" <$> inlinesToJATS opts lst
inlineToJATS opts (Subscript lst) =
  inTagsSimple "sub" <$> inlinesToJATS opts lst
inlineToJATS opts (SmallCaps lst) =
  inTagsSimple "sc" <$> inlinesToJATS opts lst
inlineToJATS opts (Quoted SingleQuote lst) = do
  contents <- inlinesToJATS opts lst
  return $ char '‘' <> contents <> char '’'
inlineToJATS opts (Quoted DoubleQuote lst) = do
  contents <- inlinesToJATS opts lst
  return $ char '“' <> contents <> char '”'
inlineToJATS opts (Code a str) =
  return $ inTags False "monospace" attr $ literal (escapeStringForXML str)
    where (_lang, attr) = codeAttr opts a
inlineToJATS _ il@(RawInline f x)
  | f == "jats" = return $ literal x
  | otherwise   = do
      report $ InlineNotRendered il
      return empty
inlineToJATS _ LineBreak = return cr -- not allowed as child of p
-- see https://jats.nlm.nih.gov/publishing/tag-library/1.2/element/break.html
inlineToJATS _ Space = return space
inlineToJATS opts SoftBreak
  | writerWrapText opts == WrapPreserve = return cr
  | otherwise = return space
inlineToJATS opts (Note contents) = do
  tagSet <- asks jatsTagSet
  -- Footnotes must occur inline when using the Article Authoring tag set.
  if tagSet == TagSetArticleAuthoring
    then inTagsIndented "fn" <$> wrappedBlocksToJATS (not . isPara) opts contents
    else do
      notes <- gets jatsNotes
      let notenum = case notes of
                      (n, _):_ -> n + 1
                      []       -> 1
      thenote <- inTags True "fn" [("id", "fn" <> tshow notenum)]
                     . (inTagsSimple "label" (literal $ tshow notenum) <>)
                    <$> wrappedBlocksToJATS (not . isPara) opts
                         (walk demoteHeaderAndRefs contents)
      modify $ \st -> st{ jatsNotes = (notenum, thenote) : notes }
      return $ inTags False "xref" [("ref-type", "fn"),
                                    ("rid", "fn" <> tshow notenum)]
             $ text (show notenum)
inlineToJATS opts (Cite _ lst) =
  inlinesToJATS opts lst
inlineToJATS opts (Span (ident,classes,kvs) ils) = do
  contents <- inlinesToJATS opts ils
  let commonAttr = [("id", escapeNCName ident) | not (T.null ident)] ++
                   [("xml:lang",l) | ("lang",l) <- kvs] ++
                   [(k,v) | (k,v) <- kvs,  k `elem` ["alt", "specific-use"]]
  -- A named-content element is a good fit for spans, but requires a
  -- content-type attribute to be present. We use either the explicit
  -- attribute or the first class as content type. If neither is
  -- available, then we fall back to using a @styled-content@ element.
  let (tag, specificAttr) =
        case lookup "content-type" kvs <|> listToMaybe classes of
          Just ct -> ( "named-content"
                     , ("content-type", ct) :
                       [(k, v) | (k, v) <- kvs
                       , k `elem` ["rid", "vocab", "vocab-identifier",
                                   "vocab-term", "vocab-term-identifier"]])
          -- Fall back to styled-content
          Nothing -> ("styled-content"
                     , [(k, v) | (k,v) <- kvs
                       , k `elem` ["style", "style-type", "style-detail",
                                   "toggle"]])
  let attr = commonAttr ++ specificAttr
  -- unwrap if wrapping element would have no attributes
  return $
    if null attr
    then contents
    else inTags False tag attr contents
inlineToJATS _ (Math t str) = do
  let addPref (Xml.Attr q v)
         | Xml.qName q == "xmlns" = Xml.Attr q{ Xml.qName = "xmlns:mml" } v
         | otherwise = Xml.Attr q v
  let fixNS' e = e{ Xml.elName =
                         (Xml.elName e){ Xml.qPrefix = Just "mml" } }
  let fixNS = everywhere (mkT fixNS') .
              (\e -> e{ Xml.elAttribs = map addPref (Xml.elAttribs e) })
  let conf = Xml.useShortEmptyTags (const False) Xml.defaultConfigPP
  res <- convertMath writeMathML t str
  let tagtype = case t of
                     DisplayMath -> "disp-formula"
                     InlineMath  -> "inline-formula"

  let rawtex = text "<![CDATA[" <> literal str <> text "]]>"
  let texMath = inTagsSimple "tex-math" rawtex

  tagSet <- asks jatsTagSet
  return . inTagsSimple tagtype $
    case res of
      Right r  -> let mathMl = text (Xml.ppcElement conf $ fixNS r)
                  -- tex-math is unsupported in Article Authoring tag set
                  in if tagSet == TagSetArticleAuthoring
                     then mathMl
                     else inTagsSimple "alternatives" $
                          cr <> texMath $$ mathMl
      Left _   -> if tagSet /= TagSetArticleAuthoring
                  then texMath
                  else rawtex
inlineToJATS _ (Link _attr [Str t] (T.stripPrefix "mailto:" -> Just email, _))
  | escapeURI t == email =
  return $ inTagsSimple "email" $ literal (escapeStringForXML email)
inlineToJATS opts (Link (ident,_,kvs) txt (T.uncons -> Just ('#', src), _)) = do
  let attr = mconcat
             [ [("id", escapeNCName ident) | not (T.null ident)]
             , [("alt", stringify txt) | not (null txt)]
             , [("rid", escapeNCName src)]
             , [(k,v) | (k,v) <- kvs, k `elem` ["ref-type", "specific-use"]]
             , [("ref-type", "bibr") | "ref-" `T.isPrefixOf` src]
             ]
  if null txt
     then return $ selfClosingTag "xref" attr
     else do
        contents <- inlinesToJATS opts txt
        return $ inTags False "xref" attr contents
inlineToJATS opts (Link (ident,_,kvs) txt (src, tit)) = do
  let attr = [("id", escapeNCName ident) | not (T.null ident)] ++
             [("ext-link-type", "uri"),
              ("xlink:href", src)] ++
             [("xlink:title", tit) | not (T.null tit)] ++
             [(k,v) | (k,v) <- kvs, k `elem` ["assigning-authority",
                                              "specific-use", "xlink:actuate",
                                              "xlink:role", "xlink:show",
                                              "xlink:type"]]
  contents <- inlinesToJATS opts txt
  return $ inTags False "ext-link" attr contents
inlineToJATS _ (Image attr alt tgt) = do
  let elattr = graphicAttr attr alt tgt
  return $ case altToJATS alt of
             Nothing -> selfClosingTag "inline-graphic" elattr
             Just altTag -> inTags True "inline-graphic" elattr altTag

graphic :: Attr -> [Inline] -> Target -> (Doc Text)
graphic attr alt tgt =
  let elattr = graphicAttr attr alt tgt
  in case altToJATS alt of
       Nothing -> selfClosingTag "graphic" elattr
       Just altTag -> inTags True "graphic" elattr altTag

graphicAttr :: Attr -> [Inline] -> Target -> [(Text, Text)]
graphicAttr (ident, _, kvs) _alt (src, tit) =
  let (maintype, subtype) = imageMimeType src kvs
  in [("id", escapeNCName ident) | not (T.null ident)] ++
     [ ("mimetype", maintype)
     , ("mime-subtype", subtype)
     , ("xlink:href", src)
     ] ++
     [("xlink:title", tit) | not (T.null tit)] ++
     [(k,v) | (k,v) <- kvs
            , k `elem` [ "baseline-shift", "content-type", "specific-use"
                       , "xlink:actuate", "xlink:href", "xlink:role"
                       , "xlink:show", "xlink:type"]
            ]

altToJATS :: [Inline] -> Maybe (Doc Text)
altToJATS alt =
  if null alt
  then Nothing
  else Just . inTagsSimple "alt-text" .
       hsep . map literal . T.words $ stringify alt

imageMimeType :: Text -> [(Text, Text)] -> (Text, Text)
imageMimeType src kvs =
  let mbMT = getMimeType (T.unpack src)
      maintype = fromMaybe "image" $
                  lookup "mimetype" kvs `mplus`
                  (T.takeWhile (/='/') <$> mbMT)
      subtype = fromMaybe "" $
                  lookup "mime-subtype" kvs `mplus`
                  (T.drop 1 . T.dropWhile (/='/') <$> mbMT)
  in (maintype, subtype)

isParaOrList :: Block -> Bool
isParaOrList Para{}           = True
isParaOrList Plain{}          = True
isParaOrList BulletList{}     = True
isParaOrList OrderedList{}    = True
isParaOrList DefinitionList{} = True
isParaOrList _                = False

isPara :: Block -> Bool
isPara Para{}  = True
isPara Plain{} = True
isPara _       = False

demoteHeaderAndRefs :: Block -> Block
demoteHeaderAndRefs (Header _ _ ils) = Para ils
demoteHeaderAndRefs (Div ("refs",cls,kvs) bs) =
                       Div ("",cls,kvs) bs
demoteHeaderAndRefs x = x

parseDate :: Text -> Maybe Day
parseDate s = msum (map (`parsetimeWith` T.unpack s) formats)
  where parsetimeWith = parseTimeM True defaultTimeLocale
        formats = ["%x","%m/%d/%Y", "%D","%F", "%d %b %Y",
                    "%e %B %Y", "%b. %e, %Y", "%B %e, %Y",
                    "%Y%m%d", "%Y%m", "%Y"]
