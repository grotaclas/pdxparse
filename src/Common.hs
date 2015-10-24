{-# LANGUAGE OverloadedStrings, PatternGuards #-}
module Common where

import Debug.Trace

import Data.Char
import Data.List
import Data.Maybe
import Data.Monoid
import Control.Applicative

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL

import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM

import Data.Set (Set)
import qualified Data.Set as S

import Text.PrettyPrint.Leijen.Text hiding ((<>), (<$>), int, double)
import qualified Text.PrettyPrint.Leijen.Text as PP

import Abstract
import Localization

isTag :: Text -> Bool
isTag s = T.length s == 3 && T.all isUpper s

isPronoun :: Text -> Bool
isPronoun s = T.map toLower s `S.member` pronouns where
    pronouns = S.fromList
        ["root"
        ,"prev"
        ,"owner"
        ,"controller"
        ]

pp_script :: Int -> L10n -> GenericScript -> Doc
pp_script indent l10n script
    = hcat . punctuate line
        . map ((mconcat (replicate indent "*" ++ [" "]) <>)
                . pp_statement' indent l10n
              ) $ script

-- Pretty-print a number, adding wiki formatting:
-- * {{green}} if good
-- * {{red}} if bad
-- * '''boldface''' if neutral
-- What is good or bad is determined by the first argument:
-- * if True, positive is good and negative is bad (e.g. stability)
-- * if False, negative is good and positive is bad (e.g. inflation)
-- * Either way, zero is neutral.
pp_hl_num :: (Ord n, PPSep n) => Bool -> (n -> Doc) -> n -> Doc
pp_hl_num pos pp_num n =
    let sign = signum n
        positivity = if pos then sign else negate sign
        n_pp'd = pp_signed pp_num n
    in case positivity of
        -1 -> template "red" n_pp'd
        0 ->  bold n_pp'd
        1 ->  template "green" n_pp'd

-- Pretty-print a number, adding &#8239; (U+202F NARROW NO-BREAK SPACE) at
-- every power of 1000.
class Num a => PPSep a where
    pp_num_sep :: a -> Doc

group3 :: [a] -> [[a]]
group3 = unfoldr (\cs -> if null cs then Nothing else Just (splitAt 3 cs))

instance PPSep Integer where
    pp_num_sep n = strictText . T.pack $
            (if n < 0 then "-" else "") <> pp_int_sep' (abs n)
        where pp_int_sep' = concat . reverse
                            . intersperse "&#8239;"
                            . map reverse 
                            . group3 
                            . reverse
                            . show

instance PPSep Int where
    pp_num_sep = pp_num_sep . toInteger

instance PPSep Double where
    pp_num_sep n = int_pp'd <> decimal <> frac_pp'd
        where (intPart, fracPart) = properFraction n
              int_pp'd = pp_num_sep (intPart::Integer)
              frac_raw = drop 2 . show . abs $ fracPart -- drop "0."
              decimal = if fracPart == 0 then "" else "."
              frac_pp'd = if fracPart == 0 then ""
                            else strictText . T.pack
                                    . mconcat . intersperse "&#8239;"
                                    . group3 $ frac_raw

-- Simple template (one arg).
-- NB: This does not perform escaping of pipes (i.e. replacing them with
-- {{!}}), because I don't know how to do that with Docs.
template :: Text -> Doc -> Doc
template name content = hcat ["{{", strictText name, "|", content, "}}"]

-- Emit flag template if the argument is a tag.
flag :: L10n -> Text -> Doc
flag l10n name =
    if isTag name
        then template "flag" (strictText $ HM.lookupDefault name name l10n)
        else strictText name

-- Emit icon template.
icon :: Text -> Doc
icon what = template "icon" (strictText what)

-- Set doc in italics.
italic :: Doc -> Doc
italic content = enclose "''" "''" content

-- Set doc in boldface.
bold :: Doc -> Doc
bold content = enclose "'''" "'''" content

-- Emit an icon template followed by some text, separated by space.
labelIcon :: Doc -> Doc -> Doc
labelIcon label content = hsep [template "icon" label, content]

-- Surround a doc in a <pre> element.
pre_statement :: GenericStatement -> Doc
pre_statement stmt = "<pre>" <> genericStatement2doc stmt <> "</pre>"

-- Pretty-print a statement, preceding it with a single layer of bullets.
-- Most statements are expected to be of a particular form. If they're not, we
-- just echo the statement instead of failing. This is also what we do with
-- unrecognized statements.
pp_statement :: L10n -> GenericStatement -> Doc
pp_statement = pp_statement' 1

-- Pretty-print a statement, preceding it with the given number of bullets.
pp_statement' :: Int -> L10n -> GenericStatement -> Doc
pp_statement' indent l10n stmt@(Statement lhs rhs) =
    let defaultdoc = pre_statement stmt
        compound = generic_compound defaultdoc indent l10n
        -- not computed if not needed, thanks to laziness
    in case lhs of
        GenericLhs label -> case label of
            -- Statements where RHS is irrelevant (usually "yes")
            "add_cardinal"          -> "Gain a cardinal"
            "kill_heir"             -> "Heir dies"
            "kill_ruler"            -> "Ruler dies"
            "remove_cardinal"       -> "Lose a cardinal"
            -- Gain/lose
            "add_adm_power" -> gain Nothing True (Just "adm") "administrative power" stmt
            "add_army_tradition" -> gain Nothing True (Just "army tradition") "army tradition" stmt
            "add_base_tax" -> gain Nothing False (Just "base tax") "base tax" stmt
            "add_dip_power" -> gain Nothing True (Just "dip") "diplomatic power" stmt
            "add_heir_claim" -> gain (Just "Heir") True Nothing "claim strength" stmt
            "add_imperial_influence" -> gain Nothing False (Just "imperial authority") "imperial authority" stmt
            "add_inflation" -> gain Nothing False (Just "inflation") "inflation" stmt
            "add_legitimacy" -> gain Nothing False (Just "legitimacy") "legitimacy" stmt
            "add_local_autonomy" -> gain Nothing False (Just "local autonomy") "local autonomy" stmt
            "add_manpower" -> gain_manpower stmt
            "add_mil_power" -> gain Nothing True (Just "mil") "military power" stmt
            "add_prestige" -> gain Nothing True (Just "prestige") "prestige" stmt
            "add_stability" -> gain Nothing True (Just "stability") "stability" stmt
            "add_war_exhaustion" -> gain Nothing False (Just "war exhaustion") "war exhaustion" stmt
            "change_adm" -> gain (Just "Ruler") True (Just "adm") "administrative skill" stmt
            "change_dip" -> gain (Just "Ruler") True (Just "dip") "diplomatic skill" stmt
            "change_mil" -> gain (Just "Ruler") True (Just "mil") "military skill" stmt
            "change_siege" -> gain Nothing True Nothing "siege progress" stmt
            -- Modifiers
            "add_country_modifier" -> add_modifier "country" l10n stmt
            "add_permanent_province_modifier" -> add_modifier "permanent province" l10n stmt
            "add_province_modifier" -> add_modifier "province" l10n stmt
            "add_ruler_modifier" -> add_modifier "ruler" l10n stmt
            "has_country_modifier" -> has_modifier "country" l10n stmt
            "has_province_modifier" -> has_modifier "province" l10n stmt
            "remove_country_modifier" -> remove_modifier "country" l10n stmt
            "remove_province_modifier" -> remove_modifier "province" l10n stmt
            -- Simple compound statements
            -- Note that "any" can mean "all" or "one or more" depending on context.
            "AND" -> compound "All of" stmt
            -- These two are ugly, but without further analysis we can't know
            -- what it means.
            "FROM"                      -> compound "FROM" stmt
            "PREV"                      -> compound "PREV" stmt
            "NOT"                       -> compound "None of" stmt
            "OR"                        -> compound "At least one of" stmt
            -- There is a semantic distinction between "all" and "every",
            -- namely that the former means "this is true for all <type>" while
            -- the latter means "do this for every <type>." But their contexts
            -- are disjoint, so they can be presented the same way.
            "all_owned_province"        -> compound "Every owned province" stmt
            "any_core_country"          -> compound "Any country with a core" stmt
            "any_country"               -> compound "Any country" stmt
            "any_known_country"         -> compound "Any known country" stmt
            "any_neighbor_country"      -> compound "Any neighboring country" stmt
            "any_neighbor_province"     -> compound "Any neighboring province" stmt
            "any_owned_province"        -> compound "Any owned province" stmt
            "any_rival_country"         -> compound "Any rival" stmt
            "capital_scope"             -> compound "Capital" stmt
            "controller"                -> compound "Province controller" stmt
            "emperor"                   -> compound "The Holy Roman Emperor" stmt
            "every_country"             -> compound "Every country in the world" stmt
            "every_enemy_country"       -> compound "Every enemy country" stmt
            "every_known_country"       -> compound "Every known country" stmt
            "every_neighbor_country"    -> compound "Every neighboring country" stmt
            "every_owned_province"      -> compound "Every owned province" stmt
            "every_province"            -> compound "Every province in the world" stmt
            "every_subject_country"     -> compound "Every subject country" stmt
            "hidden_effect"             -> compound "Hidden effect" stmt
            "if"                        -> compound "If" stmt
            "limit"                     -> compound "Limited to" stmt
            "owner"                     -> compound "Province owner" stmt
            "random_core_country"       -> compound "One random country with a core" stmt
            "random_country"            -> compound "One random country" stmt
            "random_list"               -> compound "One of the following at random" stmt
            "random_neighbor_country"   -> compound "One random neighboring country" stmt
            "random_neighbor_province"  -> compound "One random neighboring province" stmt
            "random_owned_province"     -> compound "One random owned province" stmt
            "random_province"           -> compound "One random province" stmt
            -- Random
            "random" -> random indent l10n stmt
            -- Simple generic statements (RHS is a localizable atom)
            "continent"         -> simple_generic l10n "Continent is" stmt mempty
            "culture"           -> simple_generic l10n "Culture is" stmt mempty
            "culture_group"     -> simple_generic l10n "Culture is in" stmt "culture group"
            "government"        -> simple_generic l10n "Government is" stmt mempty
            "change_government" -> simple_generic l10n "Change government to" stmt mempty
            "primary_culture"   -> simple_generic l10n "Primary culture is" stmt mempty
            "region"            -> simple_generic l10n "Is in region" stmt mempty
            "kill_advisor"      -> simple_generic l10n mempty stmt "dies"
            "remove_advisor"    -> simple_generic l10n mempty stmt "leaves the country's court"
            "infantry"          -> simple_generic l10n "An infantry regiment spawns in" stmt mempty
            -- RHS is a province ID
            "province_id"   -> simple_province l10n "Province is" stmt mempty
            "owns"          -> simple_province l10n "Owns" stmt mempty
            -- Simple generic statements (typewriter face)
            "set_country_flag"  -> simple_generic_tt "Set country flag" stmt
            "set_province_flag" -> simple_generic_tt "Set province flag" stmt
            "set_global_flag"   -> simple_generic_tt "Set global flag" stmt
            "has_country_flag"  -> simple_generic_tt "Has country flag" stmt
            "has_province_flag" -> simple_generic_tt "Has province flag" stmt
            "has_global_flag"   -> simple_generic_tt "Global flag is set:" stmt
            "clr_country_flag"  -> simple_generic_tt "Clear country flag" stmt
            "clr_province_flag" -> simple_generic_tt "Clear province flag" stmt
            -- Simple generic statements with icon
            "trade_goods"       -> generic_icon l10n "Produces" stmt
            "advisor"           -> generic_icon l10n "Has" stmt
            "create_advisor"    -> generic_icon l10n "Gain" stmt
            "has_idea_group"    -> generic_icon l10n "Has activated" stmt
            "change_trade_goods" -> generic_icon l10n "Change trade goods produced to" stmt
            -- Simple generic statements with flag
            "cede_province"     -> generic_tag l10n (Just "Cede province to") stmt Nothing
            "controlled_by"     -> generic_tag l10n (Just "Is controlled by") stmt Nothing
            "defensive_war_with" -> generic_tag l10n (Just "Is in a defensive war against") stmt Nothing
            "discover_country"  -> generic_tag l10n (Just "Discovered by") stmt Nothing
            "add_claim"         -> generic_tag l10n Nothing stmt (Just "gains a claim")
            "has_discovered"    -> generic_tag l10n (Just "Has discovered") stmt Nothing
            "inherit"           -> generic_tag l10n (Just "Inherit") stmt Nothing
            "is_core"           -> generic_tag l10n (Just "Is core of") stmt Nothing
            "is_neighbor_of"    -> generic_tag l10n (Just "Neighbors") stmt Nothing
            "remove_core"       -> generic_tag l10n Nothing stmt (Just "loses core")
            "marriage_with"     -> generic_tag l10n (Just "Has a royal marriage with") stmt Nothing
            "offensive_war_with" -> generic_tag l10n (Just "Is in an offensive war against") stmt Nothing
            "owned_by"          -> generic_tag l10n (Just "Is owned by") stmt Nothing
            "release"           -> generic_tag l10n (Just "Releases") stmt (Just "as a vassal")
            "sieged_by"         -> generic_tag l10n (Just "Is under siege by") stmt Nothing
            "tag"               -> generic_tag l10n (Just "Is") stmt Nothing
            "war_with"          -> generic_tag l10n (Just "Is at war with") stmt Nothing
            "white_peace"       -> generic_tag l10n (Just "Makes a white peace with") stmt Nothing
            -- Simple generic statements with flag or "yes"/"no"
            "exists"            -> generic_tag_bool "Exists" "Does NOT exist" l10n Nothing stmt (Just "exists")
            -- Statements that may be an icon, a flag, or a pronoun (such as ROOT)
            "religion"          -> generic_icon_or_country l10n "Religion is" stmt
            "religion_group"    -> generic_icon_or_country l10n "Religion group is" stmt
            "change_religion"   -> generic_icon_or_country l10n "Change religion to" stmt
            -- Boolean statements
            "ai"                    -> is Nothing "AI controlled" stmt
            "has_cardinal"          -> has "a cardinal" stmt
            "has_heir"              -> has "an heir" stmt
            "has_port"              -> has "a port" stmt
            "has_regency"           -> is Nothing "in a regency" stmt
            "has_siege"             -> is Nothing "under siege" stmt
            "is_at_war"             -> is Nothing "at war" stmt
            "is_capital"            -> is Nothing "capital" stmt
            "is_city"               -> is (Just "Province") "a city" stmt
            "is_emperor"            -> is Nothing "Holy Roman Emperor" stmt
            "is_female"             -> is_female stmt
            "is_lesser_in_union"    -> is Nothing "the junior partner in a personal union" stmt
            "is_looted"             -> is Nothing "looted" stmt
            "is_monarch_leader"     -> is (Just "Monarch") "a military leader" stmt
            "is_part_of_hre"        -> is Nothing "part of the Holy Roman Empire" stmt
            "is_reformation_center" -> is Nothing "a center of reformation" stmt
            "is_subject"            -> is Nothing "a subject nation" stmt
            "papacy_active"         -> is (Just "Papal interaction") "active" stmt
            "was_player"            -> has_been Nothing "player-controlled" stmt
            -- Numeric statements
            "base_tax"                  -> simple_numeric "Base tax is at least" stmt mempty
            "colonysize"                -> simple_numeric "Colony has at least" stmt "settlers"
            "development"               -> simple_numeric "Has at least" stmt "development"
            "had_recent_war"            -> simple_numeric "Was at war within the last" stmt "months(?)"
            "heir_age"                  -> simple_numeric "Heir is at least" stmt "years old"
            "is_year"                   -> simple_numeric "Year is" stmt "or later"
            "manpower_percentage"       -> manpower_percentage stmt
            "num_of_cardinals"          -> simple_numeric "Controls at least" stmt "cardinals"
            "num_of_mercenaries"        -> simple_numeric "Has at least" stmt "mercenary regiment(s)"
            "total_number_of_cardinals" -> simple_numeric "There are at least" stmt "cardinals"
            -- Statements that may be numeric or a tag
            "num_of_cities"             -> numeric_or_tag l10n "Owns" "many" stmt "cities"
            -- Percentage statements
            "local_autonomy" -> simple_percentage "Has at least" stmt "local autonomy"
            -- Signed numeric statements
            "stability" -> simple_numeric_signed "Stability is at least" stmt mempty
            "tolerance_to_this" -> simple_numeric_signed "Tolerance to this religion is at least" stmt mempty
            "war_score" -> simple_numeric_signed "Warscore is at least" stmt mempty
            -- Statements of numeric quantities with icons
            "adm" -> numeric_icon "Has at least" (Just "adm") "administrative skill" stmt
            "adm_tech" -> numeric_icon "Has at least" Nothing "administrative technology" stmt
            "dip" -> numeric_icon "Has at least" (Just "dip") "diplomatic skill" stmt
            "dip_tech" -> numeric_icon "Has at least" Nothing "diplomatic technology" stmt
            "mil" -> numeric_icon "Has at least" (Just "mil") "military skill" stmt
            "mil_tech" -> numeric_icon "Has at least" Nothing "military technology" stmt
            "legitimacy" -> numeric_icon "Has at least" Nothing "legitimacy" stmt
            "war_exhaustion" -> numeric_icon "Has at least" Nothing "war exhaustion" stmt
            -- Complex statements
            "add_casus_belli"         -> add_casus_belli l10n False stmt
            "add_faction_influence"   -> faction_influence stmt
            "add_opinion"             -> opinion l10n "Add" stmt
            "add_years_of_income"     -> add_years_of_income stmt
            "build_to_forcelimit"     -> build_to_forcelimit indent stmt
            "country_event"           -> trigger_event l10n "country" stmt
            "declare_war_with_cb"     -> declare_war_with_cb l10n stmt
            "define_ruler"            -> define_ruler stmt
            "had_country_flag"        -> had_flag "country" stmt
            "had_province_flag"       -> had_flag "province" stmt
            "has_opinion_modifier"    -> opinion l10n "Has" stmt
            "province_event"          -> trigger_event l10n "province" stmt
            "reverse_add_casus_belli" -> add_casus_belli l10n False stmt
            -- Rebels
            "create_revolt" -> spawn_rebels l10n Nothing stmt
            "has_spawned_rebels" -> has_spawned_rebels stmt
            "likely_rebels" -> can_spawn_rebels l10n stmt
            "nationalist_rebels" -> spawn_rebels l10n (Just "Nationalist rebels") stmt
            "spawn_rebels" -> spawn_rebels l10n Nothing stmt
            -- Special
            "add_core"          -> add_core l10n stmt
            -- Ignored
            "custom_tooltip" -> "(custom tooltip - delete this line)"
            "tooltip" -> "(explanatory tooltip - delete this line)"
            -- default
            _ -> if isTag label
                 then case rhs of
                    CompoundRhs scr ->
                        flag l10n (HM.lookupDefault label label l10n)
                        <> ":"
                        <> line <> pp_script (succ indent) l10n scr
                    _ -> defaultdoc
                 else defaultdoc
        IntLhs n -> case rhs of -- Treat as a province tag
            CompoundRhs scr ->
                let provN = T.pack (show n)
                in hcat
                    ["Province"
                    ,space
                    ,strictText (HM.lookupDefault ("Province " <> provN) ("PROV" <> provN) l10n)
                    ,":"
                    ,line
                    ,pp_script (succ indent) l10n scr
                    ]
            _ -> defaultdoc


------------------------------------------------------------------------
-- Script handlers that should be used directly, not via pp_statement --
------------------------------------------------------------------------

data MTTH = MTTH
        {   years :: Maybe Int
        ,   months :: Maybe Int
        ,   days :: Maybe Int
--        ,   factors :: [GenericStatement] -- TODO
        } deriving Show
newMTTH = MTTH Nothing Nothing Nothing --[]
addField mtth _ = mtth -- unrecognized
pp_mtth :: L10n -> GenericScript -> Doc
pp_mtth l10n scr
    = pp_mtth $ foldl' addField newMTTH scr
    where
        addField mtth (Statement (GenericLhs "years") (IntRhs n))
            = mtth { years = Just n }
        addField mtth (Statement (GenericLhs "years") (FloatRhs n))
            = mtth { years = Just (floor n) }
        addField mtth (Statement (GenericLhs "months") (IntRhs n))
            = mtth { months = Just n }
        addField mtth (Statement (GenericLhs "months") (FloatRhs n))
            = mtth { months = Just (floor n) }
        addField mtth (Statement (GenericLhs "days") (IntRhs n))
            = mtth { days = Just n }
        addField mtth (Statement (GenericLhs "days") (FloatRhs n))
            = mtth { days = Just (floor n) }
        addField mtth (Statement (GenericLhs "modifier") (CompoundRhs rhs))
        --            = addFactor mtth rhs
            = mtth -- TODO
        pp_mtth mtth@(MTTH years months days) =
            let hasYears = isJust years
                hasMonths = isJust months
                hasDays = isJust days
            in mconcat $
                ((if hasYears then
                    [PP.int (fromJust years), space, "years"]
                    ++
                    if hasMonths && hasDays then [",", space]
                    else if hasMonths || hasDays then ["and", space]
                    else []
                 else [])
                ++
                (if hasMonths then
                    [PP.int (fromJust months), space, "months"]
                 else [])
                ++
                (if hasDays then
                    (if hasYears && hasMonths then ["and", space]
                     else []) -- if years but no months, already added "and"
                    ++
                    [PP.int (fromJust days), space, "days"]
                 else []))

--------------------------------
-- General statement handlers --
--------------------------------

generic_compound_doc :: Doc -> Int -> L10n -> Doc -> GenericStatement -> Doc
generic_compound_doc _ indent l10n header (Statement _ (CompoundRhs scr))
        = hcat
            [header, ":"
            ,line
            ,pp_script (succ indent) l10n scr
            ]
generic_compound_doc defaultdoc _ _ _ _ = defaultdoc

generic_compound :: Doc -> Int -> L10n -> Text -> GenericStatement -> Doc
generic_compound defaultdoc indent l10n header stmt
        = generic_compound_doc defaultdoc indent l10n (strictText header) stmt

-- Statement with generic on both sides translating to the form
--  <string> <l10n value>
simple_generic :: L10n -> Text -> GenericStatement -> Text -> Doc
simple_generic l10n premsg (Statement _ (GenericRhs name)) postmsg
    = hsep
        [strictText premsg
        ,strictText $ HM.lookupDefault name name l10n
        ,strictText postmsg
        ]
simple_generic _ _ stmt _ = pre_statement stmt

simple_province :: L10n -> Text -> GenericStatement -> Text -> Doc
simple_province l10n premsg (Statement lhs rhs) postmsg
    = let loc_key = "PROV" <> case rhs of
            IntRhs id -> show id
            -- Province IDs shouldn't parse as float, but unfortunately they
            -- do. Just ignore the fractional part.
            FloatRhs id -> show (round id)
      in simple_generic l10n premsg (Statement lhs (GenericRhs (T.pack loc_key))) postmsg

-- As simple_generic but definitely no l10n. Set the RHS in typewriter face
simple_generic_tt :: Text -> GenericStatement -> Doc
simple_generic_tt premsg (Statement _ (GenericRhs name))
    = mconcat [strictText $ premsg, space, "<tt>", strictText name, "</tt>"]
simple_generic_tt _ stmt = pre_statement stmt

-- Table of script atom -> icon key. Only ones that are different are listed.
scriptIconTable :: HashMap Text Text
scriptIconTable = HM.fromList
    [("master_of_mint", "master of mint")
    ,("natural_scientist", "natural scientist")
    ,("colonial_governor", "colonial governor")
    ,("diplomat", "diplomat_adv")
    ,("naval_reformer", "naval reformer")
    ,("army_organizer", "army organizer")
    ,("army_reformer", "army reformer")
    ,("grand_captain", "grand captain")
    ,("master_recruiter", "master recruiter")
    ,("military_engineer", "military engineer")
    ,("spy_ideas", "espionage")
    ]

-- As simple_generic but also add an appropriate icon before the value.
generic_icon :: L10n -> Text -> GenericStatement -> Doc
generic_icon l10n premsg (Statement (GenericLhs category) (GenericRhs name))
    = hsep
        [strictText $ premsg
        ,icon (HM.lookupDefault
                -- If nothing specified above, at least change underscores to spaces
                (T.map (\c -> if c == '_' then ' ' else c) name)
                name scriptIconTable)
        ,strictText $ HM.lookupDefault name name l10n]
generic_icon _ _ stmt = pre_statement stmt

-- As generic_icon but say "same as <foo>" if foo refers to a country
-- (in which case, add a flag if it's a specific country).
generic_icon_or_country :: L10n -> Text -> GenericStatement -> Doc
generic_icon_or_country l10n premsg (Statement (GenericLhs category) (GenericRhs name))
    = hsep $ strictText premsg :
          if isTag name || isPronoun name
            then ["same", "as", flag l10n name]
            else [icon (HM.lookupDefault name name scriptIconTable)
                 ,strictText $ HM.lookupDefault name name l10n]
generic_icon_or_country _ _ stmt = pre_statement stmt

-- Numeric statement. Allow additional text on both sides.
simple_numeric :: Text -> GenericStatement -> Text -> Doc
simple_numeric premsg (Statement _ rhs) postmsg
    = let n = case rhs of
                IntRhs n' -> fromIntegral n'
                FloatRhs n' -> n'
      in hsep
            [strictText premsg
            ,pp_float n
            ,strictText postmsg
            ]
simple_numeric _ stmt _ = pre_statement stmt

numeric_or_tag :: L10n -> Text -> Text -> GenericStatement -> Text -> Doc
numeric_or_tag l10n pre quant (Statement _ rhs) post
    = hsep [strictText pre, case rhs of
                IntRhs n -> hsep ["at least", PP.int n, strictText post]
                FloatRhs n -> hsep ["at least", pp_float n, strictText post]
                GenericRhs t -> -- assume it's a tag
                            hsep ["at least as", strictText quant, strictText post, "as", flag l10n t]
           ]

-- Percentage
simple_percentage :: Text -> GenericStatement -> Text -> Doc
simple_percentage premsg (Statement _ rhs) postmsg
    = let n = case rhs of
                IntRhs n' -> fromIntegral n'
                FloatRhs n' -> n'
      in hsep
            [strictText premsg
            ,pp_float n <> "%"
            ,strictText postmsg
            ]
simple_percentage _ stmt _ = pre_statement stmt

simple_numeric_signed :: Text -> GenericStatement -> Text -> Doc
simple_numeric_signed premsg (Statement _ rhs) postmsg
    = let n = case rhs of
                IntRhs n' -> fromIntegral n'
                FloatRhs n' -> n'
      in hsep
            [strictText premsg
            ,pp_signed pp_float n
            ,strictText postmsg
            ]

-- "Has <something>"
has :: Text -> GenericStatement -> Doc
has what (Statement _ (GenericRhs yn)) | yn `elem` ["yes","no"]
    = hsep
        [if yn == "yes" then "Has" else "Does NOT have"
        ,strictText what
        ]
has _ stmt = pre_statement stmt

-- "Is <something>" (or "<Someone> is <something>")
is :: Maybe Text -> Text -> GenericStatement -> Doc
is who what (Statement _ (GenericRhs yn)) | yn `elem` ["yes","no"]
    = let know_who = isJust who
          no = yn == "no"
      in hsep $
            (if know_who
                then [strictText (fromJust who), "is"]
                else ["Is"]) ++
            (if no then ["NOT"] else []) ++
            [strictText what]
is _ _ stmt = pre_statement stmt

-- "Has been <something>" (or "<Someone> has been <something>")
has_been :: Maybe Text -> Text -> GenericStatement -> Doc
has_been who what (Statement _ (GenericRhs yn)) | yn `elem` ["yes","no"]
    = let know_who = isJust who
          no = yn == "no"
      in hsep $
            (if know_who
                then [strictText (fromJust who), "has"]
                else ["Has"]) ++
            (if no then ["NOT"] else []) ++
            ["been", strictText what]
has_been _ _ stmt = pre_statement stmt

-- "Is female" (= yes) or "Is male" (= no)
-- Better than "is NOT male" :)
is_female :: GenericStatement -> Doc
is_female (Statement _ (GenericRhs yn)) | yn `elem` ["yes","no"]
    = hsep ["Ruler is"
           ,if yn == "yes" then "female" else "male"
           ]
is_female stmt = pre_statement stmt

-- Generic statement referring to a country. Use a flag.
generic_tag :: L10n -> Maybe Text -> GenericStatement -> Maybe Text -> Doc
generic_tag l10n prefix (Statement _ (GenericRhs who)) suffix
    = hsep $
        (maybe [] ((:[]) . strictText) prefix) ++
        [flag l10n who] ++
        (maybe [] ((:[]) . strictText) suffix)
generic_tag _ _ stmt _ = pre_statement stmt

-- Statement may have "yes"/"no" or a tag.
generic_tag_bool :: Text -> Text -> L10n -> Maybe Text -> GenericStatement -> Maybe Text -> Doc
generic_tag_bool y_text n_text _ _ (Statement _ (GenericRhs "yes")) _ = strictText y_text
generic_tag_bool y_text n_text _ _ (Statement _ (GenericRhs "no"))  _ = strictText n_text
generic_tag_bool _ _ l10n prefix stmt suffix = generic_tag l10n prefix stmt suffix

numeric_icon :: Text -> Maybe Text -> Text -> GenericStatement -> Doc
numeric_icon premsg micon what (Statement _ rhs)
    = let amt = case rhs of
            IntRhs n -> fromIntegral n
            FloatRhs n -> n
          the_icon = maybe what id micon
      in hsep
            [strictText premsg
            ,icon the_icon
            ,pp_float amt
            ,strictText what
            ]

---------------------------------
-- Specific statement handlers --
---------------------------------

data FactionInfluence = FactionInfluence {
        faction :: Maybe Text
    ,   influence :: Maybe Double
    }
newInfluence = FactionInfluence Nothing Nothing
faction_influence :: GenericStatement -> Doc
faction_influence stmt@(Statement _ (CompoundRhs scr))
    = pp_influence $ foldl' addField newInfluence scr
    where
        pp_influence inf =
            if isJust (faction inf) && isJust (influence inf)
            then
                let fac = case fromJust (faction inf) of
                            -- Celestial empire
                            "enuchs" {- sic -} -> "eunuchs influence"
                            "temples" -> "temples influence"
                            "bureaucrats" -> "bureaucrats influence"
                            -- Merchant republic
                            "mr_aristocrats" -> "aristocrats influence"
                            "mr_guilds" -> "guilds influence"
                            "mr_traders" -> "traders influence"
                in hsep
                    [icon fac
                    -- Influence can be good or bad depending on the country's
                    -- situation, so leave it neutral.
                    ,bold (pp_signed pp_float . fromJust $ influence inf)
                    ,text ((\(Just (c,cs)) -> TL.fromStrict $ T.cons (toUpper c) cs) $ T.uncons fac)
                    ]
            else pre_statement stmt
        addField :: FactionInfluence -> GenericStatement -> FactionInfluence
        addField inf (Statement (GenericLhs "faction") (GenericRhs fac)) = inf { faction = Just fac }
        addField inf (Statement (GenericLhs "influence") (FloatRhs amt)) = inf { influence = Just amt }
        addField inf (Statement (GenericLhs "influence") (IntRhs amt)) = inf { influence = Just (fromIntegral amt) }
        addField inf _ = inf -- unknown statement

add_years_of_income :: GenericStatement -> Doc
add_years_of_income stmt
    | Statement _ (IntRhs n)   <- stmt = add_years_of_income' (fromIntegral n)
    | Statement _ (FloatRhs n) <- stmt = add_years_of_income' n
    where
        add_years_of_income' howmuch = hsep
            [if howmuch < 0 then "Lose" else "Gain"
            ,icon "ducats"
            ,"ducats", "equal", "to"
            ,pp_float (abs howmuch)
            ,if abs howmuch == 1 then "year" else "years"
            ,"of", "income"
            ]

-- "Gain" or "Lose" simple numbers, e.g. army tradition.
-- First text argument is the icon key (or Nothing if none available).
-- Second text argument is text to show after it.
-- Bool is whether a gain is good.
gain :: Maybe Text -> Bool -> Maybe Text -> Text -> GenericStatement -> Doc
gain mwho good iconkey what stmt@(Statement _ rhs) =
    if isJust mhowmuch then hsep $
        (if know_who then [strictText who] else [])
        ++
        [gain_or_lose]
        ++ (if isJust iconkey then [icon (fromJust iconkey)] else [])
        ++
        [pp_hl_num good pp_num_sep howmuch
        ,strictText what
        ]
    else pre_statement stmt
    where
        know_who = isJust mwho
        who = fromJust mwho
        mhowmuch = floatRhs rhs
        howmuch :: Double
        howmuch = fromJust mhowmuch
        gain_or_lose =
            if know_who
                then if howmuch < 0 then "loses" else "gains"
                else if howmuch < 0 then "Lose" else "Gain"

data AddModifier = AddModifier {
        name :: Maybe Text
    ,   duration :: Maybe Double
    } deriving Show
newAddModifier = AddModifier Nothing Nothing

add_modifier :: Text -> L10n -> GenericStatement -> Doc
add_modifier kind l10n stmt@(Statement _ (CompoundRhs scr))
    = pp_add_modifier $ foldl' addLine newAddModifier scr
    where
        addLine :: AddModifier -> GenericStatement -> AddModifier 
        addLine apm (Statement (GenericLhs "name") (GenericRhs name)) = apm { name = Just name }
        addLine apm (Statement (GenericLhs "name") (StringRhs name)) = apm { name = Just name }
        addLine apm (Statement (GenericLhs "duration") (FloatRhs duration)) = apm { duration = Just duration }
        addLine apm _ = apm -- e.g. hidden = yes
        pp_add_modifier :: AddModifier -> Doc
        pp_add_modifier apm
            = if isJust (name apm) then
                let dur = fromJust (duration apm)
                in hsep $
                    ["Add", strictText kind, "modifier"
                    ,dquotes (strictText $
                        let key = fromJust . name $ apm
                        in  HM.lookupDefault key key l10n)
                    ]
                    ++ if isJust (duration apm) then
                        if dur < 0 then ["indefinitely"] else
                        ["for"
                        ,pp_float dur
                        ,"days"
                        ]
                    else []
              else pre_statement stmt
add_modifier _ _ stmt = pre_statement stmt

has_modifier :: Text -> L10n -> GenericStatement -> Doc
has_modifier kind l10n (Statement _ (GenericRhs label))
    = hsep
        ["Has", strictText kind, "modifier"
        ,dquotes (strictText $ HM.lookupDefault label label l10n)
        ]
has_modifier _ _ stmt = pre_statement stmt

remove_modifier :: Text -> L10n -> GenericStatement -> Doc
remove_modifier kind l10n (Statement _ (GenericRhs label))
    = hsep
        ["Remove", strictText kind, "modifier"
        ,dquotes (strictText $ HM.lookupDefault label label l10n)
        ]
remove_modifier _ _ stmt = pre_statement stmt

-- "add_core = <n>" in country scope means "Gain core on <localize PROVn>"
-- "add_core = <tag>" in province scope means "<localize tag> gains core"
add_core :: L10n -> GenericStatement -> Doc
add_core l10n (Statement _ (GenericRhs tag)) -- tag
    = hsep [flag l10n $ HM.lookupDefault tag tag l10n, "gains", "core"]
add_core l10n (Statement _ (IntRhs num)) -- province
    = hsep ["Gain", "core", "on", "province", strictText $ HM.lookupDefault provKey provKey l10n]
    where provKey = "PROV" <> T.pack (show num)
add_core l10n (Statement _ (FloatRhs num)) -- province
    = hsep ["Gain", "core", "on", "province", strictText $ HM.lookupDefault provKey provKey l10n]
    where provKey = "PROV" <> pp_float_t num
add_core _ stmt = pre_statement stmt

-- Add an opinion modifier towards someone (for a number of years).
data AddOpinion = AddOpinion {
        who :: Maybe Text
    ,   modifier :: Maybe Text
    ,   op_years :: Maybe Double
    } deriving Show
newAddOpinion = AddOpinion Nothing Nothing Nothing

opinion :: L10n -> Text -> GenericStatement -> Doc
opinion l10n verb stmt@(Statement _ (CompoundRhs scr))
    = pp_add_opinion $ foldl' addLine newAddOpinion scr
    where
        addLine :: AddOpinion -> GenericStatement -> AddOpinion
        addLine op (Statement (GenericLhs "who") (GenericRhs tag))
            = op { who = Just tag }
        addLine op (Statement (GenericLhs "modifier") (GenericRhs label))
            = op { modifier = Just label }
        addLine op (Statement (GenericLhs "years") (FloatRhs n))
            = op { op_years = Just n }
        addLine op (Statement (GenericLhs "years") (IntRhs n))
            = op { op_years = Just (fromIntegral n) }
        addLine op _ = op
        pp_add_opinion op
            = if isJust (who op) && isJust (modifier op) then
                let whom = fromJust (who op)
                    mod = fromJust (modifier op)
                in hsep $
                    [strictText verb
                    ,"opinion modifier"
                    ,dquotes $ strictText (HM.lookupDefault mod mod l10n)
                    ,"towards"
                    ,flag l10n $ HM.lookupDefault whom whom l10n
                    ]
                    ++ if isNothing (op_years op) then [] else
                    ["for"
                    ,pp_float (fromJust (op_years op))
                    ,"years"
                    ]
              else pre_statement stmt
add_opinion _ stmt = pre_statement stmt

-- Render a rebel type atom (e.g. anti_tax_rebels) as their name and icon key.
-- This is needed because all religious rebels localize as simply "Religious" -
-- we want to be more specific.
rebel_loc :: Text -> (Text,Text)
rebel_loc "polish_noble_rebels" = ("Magnates", "magnates")
rebel_loc "lollard_rebels"      = ("Lollard zealots", "lollards")
rebel_loc "catholic_rebels"     = ("Catholic zealots", "catholic zealots")
rebel_loc "protestant_rebels"   = ("Protestant zealots", "protestant zealots")
rebel_loc "reformed_rebels"     = ("Reformed zealots", "reformed zealots")
rebel_loc "orthodox_rebels"     = ("Orthodox zealots", "orthodox zealots")
rebel_loc "sunni_rebels"        = ("Sunni zealots", "sunni zealots")
rebel_loc "shiite_rebels"       = ("Shiite zealots", "shiite zealots")
rebel_loc "buddhism_rebels"     = ("Buddhist zealots", "buddhist zealots")
rebel_loc "mahayana_rebels"     = ("Mahayana zealots", "mahayana zealots")
rebel_loc "vajrayana_rebels"    = ("Vajrayana zealots", "vajrayana zealots")
rebel_loc "hinduism_rebels"     = ("Hindu zealots", "hindu zealots")
rebel_loc "confucianism_rebels" = ("Confucian zealots", "confucian zealots")
rebel_loc "shinto_rebels"       = ("Shinto zealots", "shinto zealots")
rebel_loc "animism_rebels"      = ("Animist zealots", "animist zealots")
rebel_loc "shamanism_rebels"    = ("Shamanist zealots", "shamanist zealots")
rebel_loc "totemism_rebels"     = ("Totemist zealots", "totemist zealots")
rebel_loc "coptic_rebels"       = ("Coptic zealots", "coptic zealots")
rebel_loc "ibadi_rebels"        = ("Ibadi zealots", "ibadi zealots")
rebel_loc "sikhism_rebels"      = ("Sikh zealots", "sikh zealots")
rebel_loc "jewish_rebels"       = ("Jewish zealots", "jewish zealots")
rebel_loc "norse_pagan_reformed_rebels" = ("Norse zealots", "norse zealots")
rebel_loc "inti_rebels"         = ("Inti zealots", "inti zealots")
rebel_loc "maya_rebels"         = ("Maya zealots", "maya zealots")
rebel_loc "nahuatl_rebels"      = ("Nahuatl zealots", "nahuatl zealots")
rebel_loc "tengri_pagan_reformed_rebels" = ("Tengri zealots", "tengri zealots")
rebel_loc "zoroastrian_rebels"  = ("Zoroastrian zealots", "zoroastrian zealots")
rebel_loc "ikko_ikki_rebels"    = ("Ikko-Ikkis", "ikko-ikkis")
rebel_loc "ronin_rebels"        = ("Ronin", "ronin")
rebel_loc "reactionary_rebels"  = ("Reactionaries", "reactionaries")
rebel_loc "anti_tax_rebels"     = ("Peasant rabble", "peasants")
rebel_loc "revolutionary_rebels" = ("Revolutionaries", "revolutionaries")
rebel_loc "heretic_rebels"      = ("Heretics", "heretics")
rebel_loc "religious_rebels"    = ("Religious zealots", "religious zealots")
rebel_loc "nationalist_rebels"  = ("Separatists", "separatists")
rebel_loc "noble_rebels"        = ("Noble rebels", "noble rebels")
rebel_loc "colonial_rebels"     = ("Colonial rebels", "colonial rebels") -- ??
rebel_loc "patriot_rebels"      = ("Patriot", "patriot")
rebel_loc "pretender_rebels"    = ("Pretender", "pretender")
rebel_loc "colonial_patriot_rebels" = ("Colonial Patriot", "colonial patriot") -- ??
rebel_loc "particularist_rebels" = ("Particularist", "particularist")

-- Spawn a rebel stack.
data SpawnRebels = SpawnRebels {
        rebelType :: Maybe Text
    ,   rebelSize :: Maybe Double
    ,   friend :: Maybe Text
    ,   win :: Maybe Bool
    ,   unrest :: Maybe Double -- rebel faction progress
    } deriving Show
newSpawnRebels = SpawnRebels Nothing Nothing Nothing Nothing Nothing

spawn_rebels :: L10n -> Maybe Text -> GenericStatement  -> Doc
spawn_rebels l10n mtype stmt = spawn_rebels' mtype stmt where
    spawn_rebels' Nothing stmt@(Statement _ (CompoundRhs scr))
        = pp_spawn_rebels $ foldl' addLine newSpawnRebels scr
    spawn_rebels' rtype stmt@(Statement _ (IntRhs size))
        = pp_spawn_rebels $ newSpawnRebels { rebelType = rtype, rebelSize = Just (fromIntegral size) }
    spawn_rebels' rtype stmt@(Statement _ (FloatRhs size))
        = pp_spawn_rebels $ newSpawnRebels { rebelType = rtype, rebelSize = Just size }

    addLine :: SpawnRebels -> GenericStatement -> SpawnRebels
    addLine op (Statement (GenericLhs "type") (GenericRhs tag))
        = op { rebelType = Just tag }
    addLine op (Statement (GenericLhs "size") (FloatRhs n))
        = op { rebelSize = Just n }
    addLine op (Statement (GenericLhs "friend") (GenericRhs tag))
        = op { friend = Just tag }
    addLine op (Statement (GenericLhs "win") (GenericRhs "yes"))
        = op { win = Just True }
    addLine op (Statement (GenericLhs "unrest") (FloatRhs n))
        = op { unrest = Just n }
    addLine op _ = op

    pp_spawn_rebels :: SpawnRebels -> Doc
    pp_spawn_rebels reb
        = if isJust (rebelSize reb) then
            let hasType = isJust (rebelType reb)
                rtype = fromJust (rebelType reb)
                rsize = fromJust (rebelSize reb)
                friendlyTo = fromJust (friend reb) -- not evaluated if Nothing
                reb_unrest = fromJust (unrest reb)
                (rtype_loc, rtype_icon) = rebel_loc rtype
            in (hsep $
                   (if hasType
                        then [icon rtype_icon, strictText rtype_loc]
                        else ["Rebels"])
                   ++
                   [PP.parens $ hsep ["size", pp_float (fromJust (rebelSize reb))]]
                   ++ (if isJust (friend reb) then
                   [PP.parens $ hsep ["friendly", "to",
                                        flag l10n friendlyTo]
                   ] else [])
                   ++
                   ["rise in revolt"
                   ] ++ if isJust (win reb) && fromJust (win reb) then
                   [hsep ["and", "occupy", "the", "province"]
                   ] else []
                ) <> if isJust (unrest reb) then
                hsep
                   [","
                   ,"gaining"
                   ,pp_float reb_unrest
                   ,hsep ["progress","towards","the","next","uprising"]
                   ]
                else mempty
        else pre_statement stmt

has_spawned_rebels :: GenericStatement -> Doc
has_spawned_rebels (Statement _ (GenericRhs rtype))
    = let (rtype_loc, rtype_iconkey) = rebel_loc rtype
      in hsep
            [icon rtype_iconkey
            ,strictText rtype_loc
            ,"have risen in revolt"
            ]

can_spawn_rebels :: L10n -> GenericStatement -> Doc
can_spawn_rebels l10n (Statement _ (GenericRhs rtype))
    = let (rtype_loc, rtype_iconkey) = rebel_loc rtype
      in hsep
            ["Province has"
            ,icon rtype_iconkey
            ,strictText rtype_loc
            ]

manpower_percentage :: GenericStatement -> Doc
manpower_percentage (Statement _ rhs)
    = let pc = case rhs of
            IntRhs n -> fromIntegral n -- unlikely, but could be 1
            FloatRhs n -> n
      in hsep
            ["Available manpower is at least"
            ,pp_float (pc * 100) <> "%"
            ,"of maximum"
            ]

data TriggerEvent = TriggerEvent
        { e_id :: Maybe Text
        , e_title_loc :: Maybe Text
        , e_days :: Maybe Int
        }
newTriggerEvent = TriggerEvent Nothing Nothing Nothing
trigger_event :: L10n -> Text -> GenericStatement -> Doc
trigger_event l10n category stmt@(Statement _ (CompoundRhs scr))
    = pp_trigger_event $ foldl' addLine newTriggerEvent scr
    where
        addLine :: TriggerEvent -> GenericStatement -> TriggerEvent
        addLine evt (Statement (GenericLhs "id") (GenericRhs id))
            = evt { e_id = Just id, e_title_loc = HM.lookup (id <> ".t") l10n }
        addLine evt (Statement (GenericLhs "days") rhs) = case rhs of
            IntRhs n -> evt { e_days = Just n }
            FloatRhs n -> evt { e_days = Just (round n) }
        addLine evt _ = evt
        pp_trigger_event evt
            = let have_loc = isJust (e_title_loc evt)
                  have_days = isJust (e_days evt)
                  mid = e_id evt
                  loc = e_title_loc evt
                  days = e_days evt
              in if isJust mid then hsep $
                    ["Trigger"
                    ,strictText category
                    ,"event"
                    ,dquotes (strictText (if have_loc then fromJust loc else fromJust mid))
                    ] ++ if have_days then
                        ["in"
                        ,PP.int (fromJust days)
                        ,"day(s)"
                        ]
                    else []
                 else pre_statement stmt

gain_manpower :: GenericStatement -> Doc
gain_manpower (Statement _ rhs) =
    let amt = case rhs of
            IntRhs n -> fromIntegral n
            FloatRhs n -> n
        gain_or_lose = if amt < 0 then "Lose" else "Gain"
    in hsep
        [gain_or_lose
        ,icon "manpower"
        ,pp_hl_num True pp_float amt
        ,"months worth of manpower"
        ]


data AddCB = AddCB
    {   acb_target :: Maybe Text
    ,   acb_target_loc :: Maybe Text
    ,   acb_type :: Maybe Text
    ,   acb_type_loc :: Maybe Text
    ,   acb_months :: Maybe Double
    }
newAddCB = AddCB Nothing Nothing Nothing Nothing Nothing
-- "direct" is False for reverse_add_casus_belli
add_casus_belli :: L10n -> Bool -> GenericStatement -> Doc
add_casus_belli l10n direct stmt@(Statement _ (CompoundRhs scr))
    = pp_add_cb $ foldl' addLine newAddCB scr where
        addLine :: AddCB -> GenericStatement -> AddCB
        addLine acb (Statement (GenericLhs "target") (GenericRhs target))
            = acb { acb_target = Just target
                  , acb_target_loc = HM.lookup target l10n }
        addLine acb (Statement (GenericLhs "type") (GenericRhs cbtype))
            = acb { acb_type = Just cbtype
                  , acb_type_loc = HM.lookup cbtype l10n }
        addLine acb (Statement (GenericLhs "months") rhs)
            = acb { acb_months = Just months }
            where months = case rhs of
                    IntRhs n -> fromIntegral n
                    FloatRhs n -> n
        pp_add_cb :: AddCB -> Doc
        pp_add_cb acb
            = let has_target = isJust (acb_target acb)
                  has_type = isJust (acb_type acb)
                  has_months = isJust (acb_months acb)
                  target_loc = maybe (fromJust (acb_target acb)) id (acb_target_loc acb)
                  type_loc = maybe (fromJust (acb_type acb)) id (acb_type_loc acb)
                  months = fromJust (acb_months acb)
              in if has_target && has_type
                 then hsep $
                       (if direct then
                            ["Gain"
                            ,dquotes (strictText type_loc)
                            ,"casus belli against"
                            ,strictText target_loc
                            ]
                        else
                            [strictText target_loc
                            ,"gains"
                            ,dquotes (strictText type_loc)
                            ,"casus belli"
                            ]
                        ) ++
                        if has_months then
                            ["for"
                            ,pp_float months
                            ,"months"
                            ]
                        else []
                 else pre_statement stmt

random :: Int -> L10n -> GenericStatement -> Doc
random indent l10n stmt@(Statement _ (CompoundRhs scr))
    | (front, back) <- break
                        (\stmt -> case stmt of 
                            Statement (GenericLhs "chance") _ -> True
                            _ -> False)
                        scr
      , not (null back) =
        let chance = case head back of
                Statement _ (IntRhs n) -> fromIntegral n
                Statement _ (FloatRhs n) -> n
            defaultdoc = pre_statement stmt
            compound = generic_compound defaultdoc indent l10n
        in generic_compound_doc
                (pre_statement stmt)
                indent l10n
                (hsep [pp_float chance <> "%","chance of"])
                (Statement undefined (CompoundRhs (front ++ tail back)))
random _ _ stmt = pre_statement stmt

data DefineRuler = DefineRuler
    {   dr_name :: Maybe Text
    ,   dr_dynasty :: Maybe Text -- can be a tag/pronoun
    ,   dr_age :: Maybe Double
    ,   dr_female :: Maybe Bool
    ,   dr_claim :: Maybe Double
    ,   dr_regency :: Maybe Bool
    ,   dr_adm :: Maybe Int
    ,   dr_dip :: Maybe Int
    ,   dr_mil :: Maybe Int
    ,   dr_fixed :: Maybe Bool
    }
newDefineRuler = DefineRuler Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

define_ruler :: GenericStatement -> Doc
define_ruler stmt@(Statement _ (CompoundRhs scr))
    = pp_define_ruler $ foldl' addLine newDefineRuler scr where
        addLine :: DefineRuler -> GenericStatement -> DefineRuler
        addLine dr stmt@(Statement (GenericLhs lhs) rhs) = case T.map toLower lhs of
            "name" ->
                let mthe_name = case rhs of
                        GenericRhs a_name -> Just a_name
                        StringRhs a_name -> Just a_name
                        _ -> Nothing
                in dr { dr_name = mthe_name }
            "dynasty" ->
                let mthe_name = case rhs of
                        GenericRhs a_name -> Just a_name
                        StringRhs a_name -> Just a_name
                        _ -> Nothing
                in dr { dr_name = mthe_name }
            "age" ->
                let mage = floatRhs rhs
                in  dr { dr_age = mage }
            "claim" ->
                let mclaim = floatRhs rhs
                in  dr { dr_claim = mclaim }
            "adm" ->
                let madm = floatRhs rhs
                in  dr { dr_adm = madm }
            "dip" ->
                let mdip = floatRhs rhs
                in  dr { dr_dip = mdip }
            "mil" ->
                let mmil = floatRhs rhs
                in  dr { dr_mil = mmil }
            "regency" -> case rhs of
                GenericRhs "yes" -> dr { dr_regency = Just True }
                GenericRhs "no" -> dr { dr_regency = Just False }
                _ -> dr
        pp_define_ruler :: DefineRuler -> Doc
        pp_define_ruler dr =
            let has_name = isJust (dr_name dr)
                name = fromJust (dr_name dr)
                has_dynasty = isJust (dr_dynasty dr)
                dynasty = fromJust (dr_dynasty dr)
                has_age = isJust (dr_age dr)
                age = fromJust (dr_age dr)
                has_female = isJust (dr_female dr)
                female = fromJust (dr_female dr)
                has_claim = isJust (dr_claim dr)
                claim = fromJust (dr_claim dr)
                has_regency = isJust (dr_regency dr)
                regency = fromJust (dr_regency dr)
                has_adm = isJust (dr_adm dr)
                adm = fromJust (dr_adm dr)
                has_dip = isJust (dr_dip dr)
                dip = fromJust (dr_dip dr)
                has_mil = isJust (dr_mil dr)
                mil = fromJust (dr_mil dr)
                has_fixed = isJust (dr_fixed dr)
                fixed = fromJust (dr_fixed dr)
            in hsep $
                ["A new"]
                ++ (if has_age
                    then [pp_float age, "year old"]
                    else [])
                ++ (if has_female
                    then [if female then "female" else "male"]
                    else [])
                ++ ["ruler"]
                ++ (if has_dynasty
                    then ["of the"
                         ,strictText dynasty
                         ,"dynasty"]
                    else [])
                ++ (if has_name
                    then ["named"
                         ,strictText name]
                    else [])
                ++ ["comes to power"]
                ++ (if has_regency
                    then [if regency then "under" else "without", "a regency council"]
                    else [])
                ++ (if has_adm || has_dip || has_mil
                    then ["with"]
                        ++ [hcat . intersperse (hcat [",", space]) . map hsep . filter (not . null) $
                            [if has_adm
                                then [icon "adm", PP.int adm]
                                else []
                            , if has_dip
                                then [icon "dip", PP.int dip]
                                else []
                            , if has_mil
                                then [icon "mil", PP.int mil]
                                else []
                            ]]
                    else [])
define_ruler stmt = pre_statement stmt

data HadFlag = HadFlag
    {   hf_flag :: Maybe Text
    ,   hf_days :: Maybe Int
    }
newHadFlag = HadFlag Nothing Nothing

had_flag :: Text -> GenericStatement -> Doc
had_flag category stmt@(Statement _ (CompoundRhs scr))
    = pp_had_flag $ foldl' addLine newHadFlag scr where
        addLine :: HadFlag -> GenericStatement -> HadFlag
        addLine dr stmt@(Statement (GenericLhs lhs) rhs) = case T.map toLower lhs of
            "flag" -> case rhs of
                GenericRhs flagname -> dr { hf_flag = Just flagname }
                StringRhs flagname -> dr { hf_flag = Just flagname }
                _ -> dr
            "days" -> dr { hf_days = floatRhs rhs }
            _ -> trace ("unknown had_flag line: " ++ show stmt) dr
        pp_had_flag :: HadFlag -> Doc
        pp_had_flag dr
            = if isJust (hf_flag dr) && isJust (hf_days dr)
              then hsep
                    ["Has had"
                    ,strictText category
                    ,"flag"
                    ,enclose "<tt>" "</tt>" (strictText (fromJust (hf_flag dr)))
                    ,"for at least"
                    ,PP.int (fromJust (hf_days dr))
                    ,"days"]
              else pre_statement stmt

data BuildToForcelimit = BuildToForcelimit
    {   btf_infantry :: Maybe Double
    ,   btf_cavalry :: Maybe Double
    ,   btf_artillery :: Maybe Double
    ,   btf_heavy_ship :: Maybe Double
    ,   btf_light_ship :: Maybe Double
    ,   btf_galley :: Maybe Double
    ,   btf_transport :: Maybe Double
    }
newBuildToForcelimit = BuildToForcelimit Nothing Nothing Nothing Nothing Nothing Nothing Nothing

build_to_forcelimit :: Int -> GenericStatement -> Doc
build_to_forcelimit indent stmt@(Statement _ (CompoundRhs scr))
    = pp_build_to_forcelimit $ foldl' addLine newBuildToForcelimit scr where
        addLine :: BuildToForcelimit -> GenericStatement -> BuildToForcelimit
        addLine dr stmt@(Statement (GenericLhs lhs) rhs)
            = let mhowmuch = floatRhs rhs
                  howmuch = fromJust mhowmuch
              in if isNothing mhowmuch
                 then dr
                 else case T.map toLower lhs of
                    "infantry"   -> dr { btf_infantry   = Just howmuch }
                    "cavalry"    -> dr { btf_cavalry    = Just howmuch }
                    "artillery"  -> dr { btf_artillery  = Just howmuch }
                    "heavy_ship" -> dr { btf_heavy_ship = Just howmuch }
                    "light_ship" -> dr { btf_light_ship = Just howmuch }
                    "galley"     -> dr { btf_galley     = Just howmuch }
                    "transport"  -> dr { btf_transport  = Just howmuch }
                    _ -> dr
        pp_build_to_forcelimit :: BuildToForcelimit -> Doc
        pp_build_to_forcelimit dr
            = let has_infantry = isJust (btf_infantry dr)
                  infantry = fromJust (btf_infantry dr)
                  has_cavalry = isJust (btf_cavalry dr)
                  cavalry = fromJust (btf_cavalry dr)
                  has_artillery = isJust (btf_artillery dr)
                  artillery = fromJust (btf_artillery dr)
                  has_heavy_ship = isJust (btf_heavy_ship dr)
                  heavy_ship = fromJust (btf_heavy_ship dr)
                  has_light_ship = isJust (btf_light_ship dr)
                  light_ship = fromJust (btf_light_ship dr)
                  has_galley = isJust (btf_galley dr)
                  galley = fromJust (btf_galley dr)
                  has_transport = isJust (btf_transport dr)
                  transport = fromJust (btf_transport dr)
                  newindent = succ indent
                  has_X :: (Bool, Double, Text, Text) -> [Doc]
                  has_X (hasit, howmuch, iconkey, text)
                      = if hasit then
                            [line
                            ,hcat (replicate newindent "*"), space
                            ,pp_float (howmuch*100),"%", space
                            ,icon iconkey, space
                            ,strictText text]
                          else []
              in hcat $
                  ["Build units up to forcelimit:"]
                  ++ concatMap has_X
                  [(has_infantry, infantry, "infantry", "infantry")
                  ,(has_cavalry, cavalry, "cavalry", "cavalry")
                  ,(has_artillery, artillery, "artillery", "artillery")
                  ,(has_heavy_ship, heavy_ship, "heavy ship", "heavy ships")
                  ,(has_light_ship, light_ship, "light ship", "light ships")
                  ,(has_galley, galley, "galley", "galleys")
                  ,(has_transport, transport, "transport", "transports")
                  ]

data DeclareWarWithCB = DeclareWarWithCB
    {   dwcb_who :: Maybe Text
    ,   dwcb_cb :: Maybe Text
    }
newDeclareWarWithCB = DeclareWarWithCB Nothing Nothing

declare_war_with_cb :: L10n -> GenericStatement -> Doc
declare_war_with_cb l10n stmt@(Statement _ (CompoundRhs scr))
    = pp_declare_war_with_cb  $ foldl' addLine newDeclareWarWithCB scr where
        addLine :: DeclareWarWithCB -> GenericStatement -> DeclareWarWithCB
        addLine dwcb stmt@(Statement (GenericLhs lhs) (GenericRhs rhs))
            = case T.map toLower lhs of
                "who"         -> dwcb { dwcb_who = Just rhs }
                "casus_belli" -> dwcb { dwcb_cb  = Just rhs }
                _ -> dwcb
        pp_declare_war_with_cb :: DeclareWarWithCB -> Doc
        pp_declare_war_with_cb dwcb
            = let has_who = isJust (dwcb_who dwcb)
                  who = fromJust (dwcb_who dwcb)
                  has_cb = isJust (dwcb_cb dwcb)
                  cb = fromJust (dwcb_cb dwcb)
              in if has_who && has_cb
                 then hsep $
                      ["Declare war on"
                      ,flag l10n who
                      ,"using"
                      ,dquotes (strictText $ HM.lookupDefault cb cb l10n)
                      ,"casus belli"
                      ]
                 else pre_statement stmt

