module Helpers exposing
    ( ShopCardCategory(..)
    , buildGameState
    , getMaxSelection
    , isDeckBuilderCard
    , isDenialCard
    , isLevelUpCard
    , isPlusBombCard
    , isSabotageCard
    , levelUpHandType
    , shopCardCategory
    , shopCardDescription
    , shopCardId
    , shopCardName
    )

import Dict
import Types exposing (..)


{-| Shop card category type
-}
type ShopCardCategory
    = ResearchCategory
    | CounterCategory
    | LogisticsCategory
    | SabotageCategory


{-| Get the ID of a shop card
-}
shopCardId : ShopCard -> String
shopCardId card =
    card.id


{-| Get the name of a shop card
-}
shopCardName : ShopCard -> String
shopCardName card =
    case card.kind of
        Types.Research inner ->
            case inner of
                LevelUpCard handType ->
                    Types.handTypeToString handType

        Types.Counter inner ->
            case inner of
                DenialCard handType ->
                    Types.handTypeToString handType

        Types.Logistics inner ->
            case inner of
                FortifyCard _ _ ->
                    "Fortify"

                AmplifyCard _ _ ->
                    "Amplify"

                SupplyDropCard _ ->
                    "Supply Drop"

                DischargeCard _ ->
                    "Discharge"

                CamoCard suit _ ->
                    case suit of
                        Hearts ->
                            "Camo ♥"

                        Diamonds ->
                            "Camo ♦"

                        Clubs ->
                            "Camo ♣"

                        Spades ->
                            "Camo ♠"

                PromoteCard _ ->
                    "Promote"

        Types.Sabotage inner ->
            case inner of
                ScramblerCard ->
                    "Scrambler"

                PlusBombCard _ ->
                    "Napalm Strikes"

                StaticFieldCard ->
                    "Static Field"

                SupplyChainCard ->
                    "Supply Chain"


{-| Get the description of a shop card
-}
shopCardDescription : ShopCard -> String
shopCardDescription card =
    case card.kind of
        Types.Research inner ->
            case inner of
                LevelUpCard handType ->
                    "Increase " ++ Types.handTypeToString handType ++ " level by 1"

        Types.Counter inner ->
            case inner of
                DenialCard handType ->
                    "Opponent cannot level up " ++ Types.handTypeToString handType ++ " this shop"

        Types.Logistics inner ->
            case inner of
                FortifyCard amount _ ->
                    "+" ++ String.fromInt amount ++ " chips to selected cards"

                AmplifyCard amount _ ->
                    "+" ++ String.fromInt amount ++ " mult to selected cards"

                SupplyDropCard _ ->
                    "Draw selected cards to your hand next round"

                DischargeCard _ ->
                    "Discard selected cards"

                CamoCard suit _ ->
                    "Change selected cards to " ++ suitToString suit

                PromoteCard _ ->
                    "Promote selected cards by 1 rank"

        Types.Sabotage inner ->
            case inner of
                ScramblerCard ->
                    "Opponent's hand is scrambled (cards face down) next round"

                PlusBombCard _ ->
                    "Add + enhancement to opponent's selected cards"

                StaticFieldCard ->
                    "Opponent cannot use enhancements next round"

                SupplyChainCard ->
                    "Opponent can only draw 3 cards next round"


{-| Get the category of a shop card
-}
shopCardCategory : ShopCard -> ShopCardCategory
shopCardCategory card =
    case card.kind of
        Types.Research _ ->
            ResearchCategory

        Types.Counter _ ->
            CounterCategory

        Types.Logistics _ ->
            LogisticsCategory

        Types.Sabotage _ ->
            SabotageCategory


{-| Get the maximum number of cards that can be selected for a shop card
-}
getMaxSelection : ShopCard -> Int
getMaxSelection card =
    case card.kind of
        Types.Research _ ->
            0

        Types.Counter _ ->
            0

        Types.Logistics inner ->
            case inner of
                FortifyCard _ maxCards ->
                    maxCards

                AmplifyCard _ maxCards ->
                    maxCards

                SupplyDropCard maxCards ->
                    maxCards

                DischargeCard maxCards ->
                    maxCards

                CamoCard _ maxCards ->
                    maxCards

                PromoteCard maxCards ->
                    maxCards

        Types.Sabotage inner ->
            case inner of
                ScramblerCard ->
                    0

                PlusBombCard maxCards ->
                    maxCards

                StaticFieldCard ->
                    0

                SupplyChainCard ->
                    0


{-| Check if a shop card is a level up card
-}
isLevelUpCard : ShopCard -> Bool
isLevelUpCard card =
    case card.kind of
        Types.Research (LevelUpCard _) ->
            True

        _ ->
            False


{-| Check if a shop card is a deck builder card (logistics)
-}
isDeckBuilderCard : ShopCard -> Bool
isDeckBuilderCard card =
    case card.kind of
        Types.Logistics _ ->
            True

        _ ->
            False


{-| Check if a shop card is a sabotage card
-}
isSabotageCard : ShopCard -> Bool
isSabotageCard card =
    case card.kind of
        Types.Sabotage _ ->
            True

        _ ->
            False


{-| Check if a shop card is a denial card
-}
isDenialCard : ShopCard -> Bool
isDenialCard card =
    case card.kind of
        Types.Counter (DenialCard _) ->
            True

        _ ->
            False


{-| Check if a shop card is a plus bomb card
-}
isPlusBombCard : ShopCard -> Bool
isPlusBombCard card =
    case card.kind of
        Sabotage (PlusBombCard _) ->
            True

        _ ->
            False


{-| Get the hand type from a level up card
-}
levelUpHandType : ShopCard -> Maybe HandType
levelUpHandType card =
    case card.kind of
        Types.Research (LevelUpCard handType) ->
            Just handType

        _ ->
            Nothing


{-| Helper to convert suit to string
-}
suitToString : Suit -> String
suitToString suit =
    case suit of
        Hearts ->
            "Hearts"

        Diamonds ->
            "Diamonds"

        Clubs ->
            "Clubs"

        Spades ->
            "Spades"


{-| Build fake GameState from PlayerView
This creates a minimal GameState that has enough data for the original view helpers to work
-}
buildGameState : Model -> PlayerView -> GameState
buildGameState model playerView =
    case playerView of
        LobbyView _ ->
            -- Shouldn't happen, but provide defaults
            { roundNumber = 1
            , playerNames = Dict.empty
            , players = Dict.empty
            , phase = Playing
            , gameStatus = Active
            , lastHandResults = Nothing
            , roundHandHistory = []
            , winnerId = Nothing
            , lastRoundWinnerId = Nothing
            , shopState = Nothing
            , shopRounds = 0
            , initialLives = 3
            , handsPerRound = 4
            , discardsPerRound = 2
            }

        PlayingView playingData ->
            let
                yourPlayerState =
                    buildYourPlayerState playingData

                opponentPlayerState =
                    buildOpponentPlayerState playingData

                playerId =
                    Maybe.withDefault "you" model.playerId
            in
            { roundNumber = playingData.roundNumber
            , playerNames =
                Dict.fromList
                    [ ( playerId, "You" )
                    , ( "opponent", playingData.opponentName )
                    ]
            , players =
                Dict.fromList
                    [ ( playerId, yourPlayerState )
                    , ( "opponent", opponentPlayerState )
                    ]
            , phase = Playing
            , gameStatus = Active
            , lastHandResults = Nothing
            , roundHandHistory = []
            , winnerId = Nothing
            , lastRoundWinnerId = Nothing
            , shopState = Nothing
            , shopRounds = 0
            , initialLives = playingData.initialLives
            , handsPerRound = playingData.handsPerRound
            , discardsPerRound = playingData.discardsPerRound
            }

        RoundEndView roundEndData ->
            let
                playerId =
                    Maybe.withDefault "you" model.playerId

                -- Build minimal PlayerState from round end data
                yourPlayerState =
                    { playerId = playerId
                    , lives = roundEndData.yourLives
                    , cardPiles = { handPile = [], drawPile = [], discardPile = [] }
                    , skillTree =
                        { highCard = 1
                        , pair = 1
                        , twoPair = 1
                        , threeOfAKind = 1
                        , straight = 1
                        , flush = 1
                        , fullHouse = 1
                        , fourOfAKind = 1
                        , straightFlush = 1
                        }
                    , handsRemaining = 0
                    , discardsRemaining = 0
                    , currentRoundScore = 0
                    , lockedInHand = Nothing
                    , readyForNextRound = False
                    , status = PlayerActive
                    , activeDebuffs = []
                    , scrambled = False
                    , faceDownCardIds = []
                    , disabledRanks = []
                    , disabledSuits = []
                    , enhancementsDisabled = False
                    , supplyChainLimited = False
                    }

                opponentPlayerState =
                    { playerId = "opponent"
                    , lives = roundEndData.opponentLives
                    , cardPiles = { handPile = [], drawPile = [], discardPile = [] }
                    , skillTree =
                        { highCard = 1
                        , pair = 1
                        , twoPair = 1
                        , threeOfAKind = 1
                        , straight = 1
                        , flush = 1
                        , fullHouse = 1
                        , fourOfAKind = 1
                        , straightFlush = 1
                        }
                    , handsRemaining = 0
                    , discardsRemaining = 0
                    , currentRoundScore = 0
                    , lockedInHand = Nothing
                    , readyForNextRound = False
                    , status = PlayerActive
                    , activeDebuffs = []
                    , scrambled = False
                    , faceDownCardIds = []
                    , disabledRanks = []
                    , disabledSuits = []
                    , enhancementsDisabled = False
                    , supplyChainLimited = False
                    }
            in
            { roundNumber = roundEndData.roundNumber
            , playerNames =
                Dict.fromList
                    [ ( playerId, roundEndData.yourName )
                    , ( "opponent", roundEndData.opponentName )
                    ]
            , players =
                Dict.fromList
                    [ ( playerId, yourPlayerState )
                    , ( "opponent", opponentPlayerState )
                    ]
            , phase = RoundEnd
            , gameStatus = Active
            , lastHandResults = Nothing
            , roundHandHistory = []
            , winnerId = Nothing
            , lastRoundWinnerId =
                if roundEndData.yourLostLife then
                    Just "opponent"

                else if roundEndData.opponentLostLife then
                    Just playerId

                else
                    Nothing
            , shopState = Nothing
            , shopRounds = 0
            , initialLives = roundEndData.yourLives
            , handsPerRound = 4
            , discardsPerRound = 2
            }

        ShopView shopData ->
            -- Shop view - minimal GameState needed for shop UI
            let
                playerId =
                    Maybe.withDefault "you" model.playerId

                -- Build minimal PlayerState records with lives for shop header
                yourPlayerState =
                    { playerId = shopData.yourPlayerId
                    , lives = shopData.yourLives
                    , cardPiles = { handPile = [], drawPile = [], discardPile = [] }
                    , skillTree = shopData.yourSkillTree
                    , handsRemaining = 0
                    , discardsRemaining = 0
                    , currentRoundScore = 0
                    , lockedInHand = Nothing
                    , readyForNextRound = False
                    , status = PlayerActive
                    , activeDebuffs = []
                    , scrambled = False
                    , faceDownCardIds = []
                    , disabledRanks = []
                    , disabledSuits = []
                    , enhancementsDisabled = False
                    , supplyChainLimited = False
                    }

                opponentPlayerState =
                    { playerId = shopData.opponentPlayerId
                    , lives = shopData.opponentLives
                    , cardPiles = { handPile = [], drawPile = [], discardPile = [] }
                    , skillTree = shopData.opponentSkillTree
                    , handsRemaining = 0
                    , discardsRemaining = 0
                    , currentRoundScore = 0
                    , lockedInHand = Nothing
                    , readyForNextRound = False
                    , status = PlayerActive
                    , activeDebuffs = []
                    , scrambled = False
                    , faceDownCardIds = []
                    , disabledRanks = []
                    , disabledSuits = []
                    , enhancementsDisabled = False
                    , supplyChainLimited = False
                    }
            in
            { roundNumber = shopData.currentRound
            , playerNames =
                Dict.fromList
                    [ ( shopData.yourPlayerId, shopData.yourName )
                    , ( shopData.opponentPlayerId, shopData.opponentName )
                    ]
            , players =
                Dict.fromList
                    [ ( shopData.yourPlayerId, yourPlayerState )
                    , ( shopData.opponentPlayerId, opponentPlayerState )
                    ]
            , phase = RoundEnd
            , gameStatus = Active
            , lastHandResults = Nothing
            , roundHandHistory = []
            , winnerId = Nothing
            , lastRoundWinnerId = Nothing
            , shopState = Just shopData.shopState
            , shopRounds = shopData.totalRounds
            , initialLives = shopData.yourLives
            , handsPerRound = 4
            , discardsPerRound = 2
            }

        GameOverView gameOverData ->
            let
                playerId =
                    Maybe.withDefault "you" model.playerId
            in
            { roundNumber = 1
            , playerNames =
                Dict.fromList
                    [ ( playerId, gameOverData.yourName )
                    , ( "opponent", gameOverData.opponentName )
                    ]
            , players = Dict.empty
            , phase = RoundEnd
            , gameStatus = GameOver
            , lastHandResults = Nothing
            , roundHandHistory = []
            , winnerId =
                if gameOverData.youWon then
                    Just playerId

                else
                    Just "opponent"
            , lastRoundWinnerId = Nothing
            , shopState = Nothing
            , shopRounds = 0
            , initialLives = gameOverData.yourFinalLives
            , handsPerRound = 4
            , discardsPerRound = 2
            }


{-| Build PlayerState record for "you" from PlayingData
-}
buildYourPlayerState : PlayingData -> PlayerState
buildYourPlayerState data =
    { playerId = "you"
    , lives = data.yourLives
    , cardPiles =
        { handPile = data.yourHand
        , drawPile = data.yourDrawPile
        , discardPile = [] -- Not tracked in PlayerView (not needed for UI)
        }
    , skillTree = data.yourSkillTree
    , handsRemaining = data.yourHandsRemaining
    , discardsRemaining = data.yourDiscardsRemaining
    , currentRoundScore = data.yourCurrentScore
    , lockedInHand = data.yourLockedInHand
    , readyForNextRound = False
    , status = PlayerActive
    , activeDebuffs = data.yourActiveDebuffs
    , scrambled = data.yourScrambled
    , faceDownCardIds = data.yourFaceDownCardIds
    , disabledRanks = data.yourDisabledRanks
    , disabledSuits = data.yourDisabledSuits
    , enhancementsDisabled = data.yourEnhancementsDisabled
    , supplyChainLimited = data.yourSupplyChainLimited
    }


{-| Build PlayerState record for opponent from PlayingData
-}
buildOpponentPlayerState : PlayingData -> PlayerState
buildOpponentPlayerState data =
    { playerId = "opponent"
    , lives = data.opponentLives
    , cardPiles =
        { handPile = data.opponentHand
        , drawPile = []
        , discardPile = []
        }
    , skillTree =
        { highCard = 1
        , pair = 1
        , twoPair = 1
        , threeOfAKind = 1
        , straight = 1
        , flush = 1
        , fullHouse = 1
        , fourOfAKind = 1
        , straightFlush = 1
        }
    , handsRemaining = data.opponentHandsRemaining
    , discardsRemaining = data.opponentDiscardsRemaining
    , currentRoundScore = data.opponentCurrentScore
    , lockedInHand = data.opponentLockedInHand
    , readyForNextRound = False
    , status = PlayerActive
    , activeDebuffs = data.opponentActiveDebuffs
    , scrambled = data.opponentScrambled
    , faceDownCardIds = data.opponentFaceDownCardIds
    , disabledRanks = data.opponentDisabledRanks
    , disabledSuits = data.opponentDisabledSuits
    , enhancementsDisabled = data.opponentEnhancementsDisabled
    , supplyChainLimited = data.opponentSupplyChainLimited
    }
