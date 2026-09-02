port module Main exposing (main)

import Browser
import Decoders exposing (..)
import Dict
import Encoders exposing (..)
import Games.Backgammon.View as Backgammon
import Games.Tilt.Adapter as Tilt
import Generic.View
import Helpers exposing (..)
import Html exposing (Html)
import Html.Attributes
import Json.Decode as D
import Json.Encode as E
import Protocol exposing (GamePayload, ServerMessage(..))
import Set exposing (Set)
import Task
import Time
import Types exposing (..)
import View.Clock
import Url exposing (percentEncode)
import View.Game



-- MAIN


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }



-- PORTS


port sendToChannel : E.Value -> Cmd msg


port receiveFromChannel : (E.Value -> msg) -> Sub msg


port navigateToUrl : String -> Cmd msg



-- FLAGS


type alias Flags =
    { gameId : String
    , gameSlug : String
    , playerId : Maybe String
    }



-- MODEL


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( { gameId = flags.gameId
      , gameSlug = flags.gameSlug
      , playerId = flags.playerId
      , payload = Nothing
      , legal = []
      , lastPlaying = Nothing
      , generic = Generic.View.init
      , backgammon = Backgammon.init
      , clockReceivedAt = 0
      , nowMs = 0
      , gameState = Loading
      , viewingModal = Nothing
      , selectedCards = Set.empty
      , newCardIds = Set.empty
      , acknowledgedEventSeq = 0
      , connectionStatus = Connecting
      , cardSort = ByRank
      , previewingCardIndex = Nothing
      , deckBuilderSelection = []
      , plusBombSelection = Nothing
      , shopUIState = Nothing
      , scoreAnimation = { phase = AnimationIdle, cardIndex = 0, nextStepTime = Nothing }
      , viewingResults = False
      , shopCountdown = Nothing
      , currentAnimationData = Nothing
      }
    , Cmd.none
    )



-- SHOP STATE DERIVATION


{-| Helper to check if it's player's turn in shop
-}
isPlayerTurnInShop : ShopState -> String -> Bool
isPlayerTurnInShop shopState playerId =
    if not shopState.firstPickMade && shopState.firstPickerId == playerId then
        True

    else if shopState.firstPickMade && not shopState.secondPickMade && shopState.secondPickerId == playerId then
        True

    else
        False


{-| Derives the client-side shop UI state from the server's ShopState.
Called on every GameStateUpdated message.
-}
deriveShopUIState : String -> ShopState -> ShopUIState
deriveShopUIState playerId shopState =
    -- Priority order matters: check phases from most specific to least specific
    if not shopState.destroyPhaseComplete then
        -- DESTROY PHASE
        DestroyPhase
            { isMyTurn = shopState.destroyerId == Just playerId
            , destroysRemaining = shopState.destroysAllowed - List.length shopState.destroyedCardIds
            , availableCards = shopState.availableCards
            , destroyedCardIds = shopState.destroyedCardIds
            }

    else if shopState.currentRound == shopState.totalRounds && shopState.firstPickMade && shopState.secondPickMade then
        -- SHOP COMPLETE
        ShopComplete
            { availableCards = shopState.availableCards
            , pickedCardIds = shopState.pickedCardIds
            , destroyedCardIds = shopState.destroyedCardIds
            }

    else
        -- PICKING PHASE - check for pending selections first
        case shopState.pendingDeckBuilder of
            Just pending ->
                if pending.playerId == playerId then
                    -- I'm in deck builder selection mode
                    SelectingDeckBuilderCards
                        { cardId = pending.shopCardId
                        , deckBuilderCard = pending.deckBuilderCard
                        , availableCards = pending.availableCards
                        , selectedCardIds = []
                        , maxSelection = getMaxSelection pending.deckBuilderCard
                        , availableShopCards = shopState.availableCards
                        , pickedCardIds = shopState.pickedCardIds
                        , destroyedCardIds = shopState.destroyedCardIds
                        }

                else
                    -- Opponent is in deck builder selection
                    WaitingForOpponent
                        { reason = OpponentPicking
                        , availableCards = shopState.availableCards
                        , pickedCardIds = shopState.pickedCardIds
                        , destroyedCardIds = shopState.destroyedCardIds
                        }

            Nothing ->
                case shopState.pendingPlusBomb of
                    Just pending ->
                        if pending.playerId == playerId then
                            -- I'm in plus bomb selection mode
                            SelectingPlusBombCard
                                { cardId = pending.shopCardId
                                , availableCards = pending.availableCards
                                , selectedCardId = Nothing
                                , availableShopCards = shopState.availableCards
                                , pickedCardIds = shopState.pickedCardIds
                                , destroyedCardIds = shopState.destroyedCardIds
                                }

                        else
                            -- Opponent is in plus bomb selection
                            WaitingForOpponent
                                { reason = OpponentPicking
                                , availableCards = shopState.availableCards
                                , pickedCardIds = shopState.pickedCardIds
                                , destroyedCardIds = shopState.destroyedCardIds
                                }

                    Nothing ->
                        -- Normal picking (no pending selections)
                        if isPlayerTurnInShop shopState playerId then
                            -- My turn to pick, browsing cards
                            BrowsingCards
                                { availableCards = shopState.availableCards
                                , pickedCardIds = shopState.pickedCardIds
                                , destroyedCardIds = shopState.destroyedCardIds
                                }

                        else
                            -- Not my turn
                            WaitingForOpponent
                                { reason = OpponentPicking
                                , availableCards = shopState.availableCards
                                , pickedCardIds = shopState.pickedCardIds
                                , destroyedCardIds = shopState.destroyedCardIds
                                }


{-| Smart derivation that preserves transient UI state when in the same phase
-}
deriveShopUIStatePreservingSelections : String -> ShopState -> Maybe ShopUIState -> ShopUIState
deriveShopUIStatePreservingSelections playerId shopState previousUIState =
    let
        newState =
            deriveShopUIState playerId shopState
    in
    case ( previousUIState, newState ) of
        -- Preserve deck builder selections if still in same selection phase
        ( Just (SelectingDeckBuilderCards prev), SelectingDeckBuilderCards new ) ->
            if prev.cardId == new.cardId then
                SelectingDeckBuilderCards { new | selectedCardIds = prev.selectedCardIds }

            else
                newState

        -- Preserve plus bomb selection if still in same selection phase
        ( Just (SelectingPlusBombCard prev), SelectingPlusBombCard new ) ->
            if prev.cardId == new.cardId then
                SelectingPlusBombCard { new | selectedCardId = prev.selectedCardId }

            else
                newState

        -- Preserve preview state ONLY if still valid
        ( Just (PreviewingCard prev), serverState ) ->
            case serverState of
                BrowsingCards newData ->
                    -- Check if previewed card is still available and actionable
                    if isCardStillValid prev.cardId newData.availableCards newData.pickedCardIds newData.destroyedCardIds then
                        -- Card still valid, preserve preview with updated data
                        PreviewingCard
                            { prev
                                | availableCards = newData.availableCards
                                , pickedCardIds = newData.pickedCardIds
                                , destroyedCardIds = newData.destroyedCardIds
                            }

                    else
                        -- Card was picked/destroyed, return to browsing
                        serverState

                DestroyPhase newData ->
                    -- Preserve preview only if in destroy mode and card still valid
                    if prev.isDestroyMode && isCardStillValid prev.cardId newData.availableCards [] newData.destroyedCardIds then
                        PreviewingCard
                            { prev
                                | availableCards = newData.availableCards
                                , destroyedCardIds = newData.destroyedCardIds
                            }

                    else
                        -- Not in destroy mode, or card destroyed, or phase changed
                        serverState

                -- For ANY other state (SelectingDeckBuilderCards, SelectingPlusBombCard,
                -- WaitingForOpponent, ShopComplete), the server has moved us to a different
                -- phase. RESPECT it - don't preserve preview.
                _ ->
                    serverState

        -- For all other cases, use the new state
        _ ->
            newState


{-| Check if a card with the given ID is still valid for preview/selection.
A card is valid if:

  - The card exists in the available cards list
  - The card hasn't been picked
  - The card hasn't been destroyed

-}
isCardStillValid : String -> List ShopCard -> List String -> List String -> Bool
isCardStillValid cardId availableCards pickedCardIds destroyedCardIds =
    List.any (\c -> shopCardId c == cardId) availableCards
        && not (List.member cardId pickedCardIds)
        && not (List.member cardId destroyedCardIds)


{-| Generate a deterministic rematch game ID
-}
generateRematchId : String -> String
generateRematchId currentId =
    -- Check if ID already has a rematch suffix (e.g., "abc123-r2")
    if String.contains "-r" currentId then
        -- Extract base and number, increment
        case String.split "-r" currentId of
            [ base, numStr ] ->
                case String.toInt numStr of
                    Just num ->
                        base ++ "-r" ++ String.fromInt (num + 1)

                    Nothing ->
                        currentId ++ "-r1"

            _ ->
                currentId ++ "-r1"

    else
        -- First rematch
        currentId ++ "-r1"



-- SCORE ANIMATION HELPERS


{-| Advance to the next animation step based on current phase and game state
-}
advanceAnimationStep : Model -> Int -> ( Model, Cmd Msg )
advanceAnimationStep model currentTime =
    case model.currentAnimationData of
        Just animData ->
            let
                firstCardCount =
                    List.length animData.opponentBreakdown.cardBreakdowns

                secondCardCount =
                    List.length animData.yourBreakdown.cardBreakdowns

                ( nextPhase, nextIndex, delayMs ) =
                    nextAnimationStep model.scoreAnimation.phase model.scoreAnimation.cardIndex firstCardCount secondCardCount

                -- Auto-dismiss when animation completes
                shouldDismiss =
                    nextPhase == AnimationComplete

                newAnimation =
                    if shouldDismiss then
                        -- Reset to idle so next animation can start
                        { phase = AnimationIdle
                        , cardIndex = 0
                        , nextStepTime = Nothing
                        }

                    else
                        { phase = nextPhase
                        , cardIndex = nextIndex
                        , nextStepTime = Just (currentTime + delayMs)
                        }
            in
            ( refreshView
                { model
                    | scoreAnimation = newAnimation
                    , viewingResults = not shouldDismiss
                }
            , Cmd.none
            )

        Nothing ->
            -- No animation data, stay idle
            ( model, Cmd.none )


{-| Animation state machine - determines next phase, card index, and delay
Matches the LiveView logic
-}
nextAnimationStep : ScoreAnimationPhase -> Int -> Int -> Int -> ( ScoreAnimationPhase, Int, Int )
nextAnimationStep currentPhase currentIndex firstCardCount secondCardCount =
    case currentPhase of
        AnimationIdle ->
            ( OpponentBase, 0, 0 )

        OpponentBase ->
            if firstCardCount > 0 then
                ( OpponentCards, 0, 400 )

            else
                ( OpponentFinal, 0, 400 )

        OpponentCards ->
            if currentIndex + 1 < firstCardCount then
                ( OpponentCards, currentIndex + 1, 600 )

            else
                ( OpponentFinal, 0, 400 )

        OpponentFinal ->
            if secondCardCount > 0 then
                ( PlayerBase, 0, 400 )

            else
                ( PlayerFinal, 0, 400 )

        PlayerBase ->
            if secondCardCount > 0 then
                ( PlayerCards, 0, 400 )

            else
                ( PlayerFinal, 0, 400 )

        PlayerCards ->
            if currentIndex + 1 < secondCardCount then
                ( PlayerCards, currentIndex + 1, 600 )

            else
                ( PlayerFinal, 0, 400 )

        PlayerFinal ->
            ( AnimationComplete, 0, 2500 )

        AnimationComplete ->
            ( AnimationComplete, 0, 0 )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ServerMessageReceived message ->
            case message of
                GameMessage payload ->
                    applyPayload payload model

                LobbyMessage ->
                    ( { model | connectionStatus = Connected }, Cmd.none )

                ErrorMessage err ->
                    update (ChannelError err) model

                RematchReadyMessage rematchGameId ->
                    update (RematchGameReady rematchGameId) model

                StatusMessage status ->
                    update (ConnectionStatusChanged (connectionStatusFromString status)) model

        GenericMsg genericMsg ->
            let
                ( generic, maybeAction ) =
                    Generic.View.update genericMsg model.generic
            in
            ( { model | generic = generic }
            , maybeAction |> Maybe.map sendToChannel |> Maybe.withDefault Cmd.none
            )

        BackgammonMsg bgMsg ->
            let
                ( bg, out ) =
                    Backgammon.update bgMsg model.backgammon

                updated =
                    { model | backgammon = bg }
            in
            case out of
                Backgammon.NoOut ->
                    ( updated, Cmd.none )

                Backgammon.Send value ->
                    ( updated, sendToChannel value )

                Backgammon.WantRematch ->
                    update RequestRematch updated

        ClockSynced posix ->
            ( { model | clockReceivedAt = Time.posixToMillis posix, nowMs = Time.posixToMillis posix }
            , Cmd.none
            )

        ClockTick posix ->
            ( { model | nowMs = Time.posixToMillis posix }, Cmd.none )

        RematchGameReady rematchGameId ->
            -- Server has created rematch game, navigate to it with player name
            let
                playerName =
                    case model.gameState of
                        Success (GameOverView gameOverData) ->
                            Just gameOverData.yourName

                        _ ->
                            Nothing

                url =
                    case playerName of
                        Just name ->
                            "/" ++ model.gameSlug ++ "/" ++ rematchGameId ++ "?name=" ++ percentEncode name

                        Nothing ->
                            "/" ++ model.gameSlug ++ "/" ++ rematchGameId
            in
            ( model
            , navigateToUrl url
            )

        ChannelError err ->
            -- Before the first payload an error is fatal; afterwards it is a
            -- rejected action and the current state stays on screen.
            case model.payload of
                Nothing ->
                    ( { model | gameState = Failure err }, Cmd.none )

                Just _ ->
                    ( model, Cmd.none )

        ConnectionStatusChanged status ->
            ( { model | connectionStatus = status }
            , Cmd.none
            )

        -- Card selection
        ToggleCardSelection cardId ->
            let
                newSelectedCards =
                    if Set.member cardId model.selectedCards then
                        Set.remove cardId model.selectedCards

                    else if Set.size model.selectedCards < 5 then
                        Set.insert cardId model.selectedCards

                    else
                        -- Already have 5 cards selected, don't add more
                        model.selectedCards
            in
            ( { model | selectedCards = newSelectedCards }
            , Cmd.none
            )

        ToggleCardSort ->
            let
                newSort =
                    case model.cardSort of
                        ByRank ->
                            BySuit

                        BySuit ->
                            ByRank
            in
            ( { model | cardSort = newSort }
            , Cmd.none
            )

        -- Game actions
        LockInHand ->
            let
                selected =
                    case model.gameState of
                        Success (PlayingView playing) ->
                            playing.yourHand
                                |> List.filter (\card -> Set.member card.id model.selectedCards)
                                |> List.map .id

                        _ ->
                            Set.toList model.selectedCards
            in
            if List.isEmpty selected then
                ( model, Cmd.none )

            else
                ( { model
                    | selectedCards = Set.empty
                    , newCardIds = Set.empty
                    , viewingModal = Nothing
                  }
                , sendToChannel (encodePlayHand selected)
                )

        DiscardCards cardIds ->
            ( { model
                | selectedCards = Set.empty
                , newCardIds = Set.empty
              }
            , sendToChannel (encodeDiscard cardIds)
            )

        MakeShopPick cardId ->
            -- Send pick command to server - let GameStateUpdated handle state transition
            -- (Don't re-derive immediately as server may set pendingPlusBomb/pendingDeckBuilder)
            ( { model | previewingCardIndex = Nothing }
            , sendToChannel (encodeShopPick cardId)
            )

        PreviewShopCard cardId ->
            -- NEW: Transition from BrowsingCards, DestroyPhase, or PreviewingCard to PreviewingCard
            -- Extract skill tree from ShopView
            let
                playerSkillTree =
                    case model.gameState of
                        Success (ShopView shopData) ->
                            shopData.yourSkillTree

                        _ ->
                            -- Fallback (shouldn't happen in shop)
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
            in
            case model.shopUIState of
                Just (BrowsingCards data) ->
                    case List.filter (\c -> c.id == cardId) data.availableCards |> List.head of
                        Just card ->
                            ( { model
                                | shopUIState =
                                    Just
                                        (PreviewingCard
                                            { cardId = cardId
                                            , card = card
                                            , availableCards = data.availableCards
                                            , pickedCardIds = data.pickedCardIds
                                            , destroyedCardIds = data.destroyedCardIds
                                            , isDestroyMode = False
                                            , skillTree = playerSkillTree
                                            }
                                        )
                                , previewingCardIndex = Nothing

                                -- Keep for backwards compat during migration
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Just (DestroyPhase data) ->
                    case List.filter (\c -> c.id == cardId) data.availableCards |> List.head of
                        Just card ->
                            ( { model
                                | shopUIState =
                                    Just
                                        (PreviewingCard
                                            { cardId = cardId
                                            , card = card
                                            , availableCards = data.availableCards
                                            , pickedCardIds = []
                                            , destroyedCardIds = data.destroyedCardIds
                                            , isDestroyMode = True
                                            , skillTree = playerSkillTree
                                            }
                                        )
                                , previewingCardIndex = Nothing
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Just (PreviewingCard data) ->
                    -- Allow switching between previewed cards
                    case List.filter (\c -> c.id == cardId) data.availableCards |> List.head of
                        Just card ->
                            ( { model
                                | shopUIState =
                                    Just
                                        (PreviewingCard
                                            { cardId = cardId
                                            , card = card
                                            , availableCards = data.availableCards
                                            , pickedCardIds = data.pickedCardIds
                                            , destroyedCardIds = data.destroyedCardIds
                                            , isDestroyMode = data.isDestroyMode
                                            , skillTree = data.skillTree
                                            }
                                        )
                                , previewingCardIndex = Nothing
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                -- Can only preview when browsing, destroying, or already previewing
                _ ->
                    ( model, Cmd.none )

        ClearCardPreview ->
            -- Go back to appropriate state (DestroyPhase if in destroy mode, BrowsingCards otherwise)
            -- TODO: Re-derive from PlayerView once shop is ported
            case model.shopUIState of
                Just (PreviewingCard data) ->
                    let
                        nextState =
                            if data.isDestroyMode then
                                DestroyPhase
                                    { isMyTurn = True
                                    , destroysRemaining = 0
                                    , availableCards = data.availableCards
                                    , destroyedCardIds = data.destroyedCardIds
                                    }

                            else
                                BrowsingCards
                                    { availableCards = data.availableCards
                                    , pickedCardIds = data.pickedCardIds
                                    , destroyedCardIds = data.destroyedCardIds
                                    }
                    in
                    ( { model
                        | shopUIState = Just nextState
                        , previewingCardIndex = Nothing
                      }
                    , Cmd.none
                    )

                _ ->
                    ( { model | previewingCardIndex = Nothing }, Cmd.none )

        ConfirmDeckBuilder cardId ->
            -- Send to server, which will set pendingDeckBuilder
            -- Next GameStateUpdated will transition us to SelectingDeckBuilderCards
            ( model
            , sendToChannel (encodeShopPick cardId)
            )

        ConfirmPlusBomb cardId ->
            -- Send to server, which will set pendingPlusBomb
            ( model
            , sendToChannel (encodeShopPick cardId)
            )

        ToggleDeckCardSelection cardId ->
            -- NEW: Toggle selection in deck builder mode with auto-deselect oldest when at max
            case model.shopUIState of
                Just (SelectingDeckBuilderCards data) ->
                    let
                        newSelected =
                            if List.member cardId data.selectedCardIds then
                                -- Deselect if already selected
                                List.filter (\id -> id /= cardId) data.selectedCardIds

                            else if List.length data.selectedCardIds < data.maxSelection then
                                -- Add to selection if under max
                                data.selectedCardIds ++ [ cardId ]

                            else
                                -- At max capacity: remove oldest (first in list) and add new one
                                List.drop 1 data.selectedCardIds ++ [ cardId ]

                        newState =
                            SelectingDeckBuilderCards { data | selectedCardIds = newSelected }
                    in
                    ( { model | shopUIState = Just newState }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SelectPlusBombCard cardId ->
            -- Update selection in plus bomb mode
            case model.shopUIState of
                Just (SelectingPlusBombCard data) ->
                    let
                        newState =
                            SelectingPlusBombCard { data | selectedCardId = Just cardId }
                    in
                    ( { model
                        | shopUIState = Just newState
                        , plusBombSelection = Just cardId
                      }
                    , Cmd.none
                    )

                _ ->
                    ( { model | plusBombSelection = Just cardId }, Cmd.none )

        ConfirmSelection ->
            -- NEW: Unified confirmation for deck builder and plus bomb
            case model.shopUIState of
                Just (SelectingDeckBuilderCards data) ->
                    let
                        selectedList =
                            data.selectedCardIds

                        cmd =
                            if List.isEmpty selectedList then
                                sendToChannel (encodeShopSelect [])

                            else
                                sendToChannel (encodeShopSelect selectedList)
                    in
                    ( model, cmd )

                Just (SelectingPlusBombCard data) ->
                    case data.selectedCardId of
                        Just cardId ->
                            ( model, sendToChannel (encodeShopSelect [ cardId ]) )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        CancelSelection ->
            -- NEW: Cancel/skip selection
            case model.shopUIState of
                Just (SelectingDeckBuilderCards _) ->
                    ( model, sendToChannel (encodeShopSelect []) )

                _ ->
                    ( model, Cmd.none )

        -- OLD HANDLERS (kept for backwards compatibility during migration)
        PreviewDeckBuilder cardId ->
            ( model
            , sendToChannel (encodeShopPick cardId)
            )

        SelectDeckCard cardId ->
            ( { model
                | deckBuilderSelection =
                    if List.member cardId model.deckBuilderSelection then
                        List.filter (\id -> id /= cardId) model.deckBuilderSelection

                    else
                        model.deckBuilderSelection ++ [ cardId ]
              }
            , Cmd.none
            )

        CompleteDeckBuilderSelection cardIds ->
            ( { model | deckBuilderSelection = [] }
            , sendToChannel (encodeShopSelect cardIds)
            )

        SkipDeckBuilderSelection ->
            ( { model | deckBuilderSelection = [] }
            , sendToChannel (encodeShopSelect [])
            )

        PreviewPlusBomb cardId ->
            ( model
            , sendToChannel (encodeShopPick cardId)
            )

        CompletePlusBombSelection cardId ->
            ( { model | plusBombSelection = Nothing }
            , sendToChannel (encodeShopSelect [ cardId ])
            )

        DestroyShopCard cardId ->
            -- Send destroy command to server - let GameStateUpdated handle state transition
            ( { model | previewingCardIndex = Nothing }
            , sendToChannel (encodeShopDestroy cardId)
            )

        CompleteDestroyPhase ->
            ( model
            , sendToChannel encodeShopFinishDestroy
            )

        ShopCountdownTick ->
            -- Decrement shop countdown and send ready when it hits 0
            case model.shopCountdown of
                Just countdown ->
                    if countdown <= 1 then
                        -- Countdown finished, clear countdown (round advances automatically)
                        ( { model | shopCountdown = Nothing }
                        , Cmd.none
                        )

                    else
                        -- Continue counting down
                        ( { model | shopCountdown = Just (countdown - 1) }
                        , Cmd.none
                        )

                Nothing ->
                    ( model, Cmd.none )

        RequestRematch ->
            ( model
            , sendToChannel encodeRequestRematch
            )

        -- Modal actions
        OpenModal modal ->
            ( { model | viewingModal = Just modal }
            , Cmd.none
            )

        CloseModal ->
            ( { model | viewingModal = Nothing }
            , Cmd.none
            )

        AdvanceScoreAnimation currentTime ->
            -- Check if it's time to advance animation
            case model.scoreAnimation.nextStepTime of
                Just nextTime ->
                    if currentTime >= nextTime then
                        advanceAnimationStep model currentTime

                    else
                        ( model, Cmd.none )

                Nothing ->
                    -- First step, start immediately
                    advanceAnimationStep model currentTime

        DismissResults ->
            ( refreshView
                { model
                    | viewingResults = False
                    , scoreAnimation = { phase = AnimationIdle, cardIndex = 0, nextStepTime = Nothing }
                }
            , Cmd.none
            )

        NoOp ->
            ( model, Cmd.none )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ receiveFromChannel handleChannelMessage
        , if model.scoreAnimation.phase /= AnimationIdle && model.scoreAnimation.phase /= AnimationComplete then
            Time.every 100 (\posix -> AdvanceScoreAnimation (Time.posixToMillis posix))

          else
            Sub.none
        , if clockRunning model then
            Time.every 200 ClockTick

          else
            Sub.none
        , -- Shop countdown timer - tick every second
          case model.shopCountdown of
            Just _ ->
                Time.every 1000 (\_ -> ShopCountdownTick)

            Nothing ->
                Sub.none
        ]


{-| Handle messages from the Phoenix channel
-}
handleChannelMessage : E.Value -> Msg
handleChannelMessage value =
    case D.decodeValue Protocol.serverMessageDecoder value of
        Ok message ->
            ServerMessageReceived message

        Err err ->
            ChannelError (D.errorToString err)


connectionStatusFromString : String -> ConnectionStatus
connectionStatusFromString status =
    case status of
        "connected" ->
            Connected

        "connecting" ->
            Connecting

        _ ->
            Disconnected



-- PAYLOAD -> VIEW


{-| Absorb a server payload: remember it, start any score reveal it carries,
highlight newly drawn cards, and rebuild the view.
-}
applyPayload : GamePayload -> Model -> ( Model, Cmd Msg )
applyPayload payload model =
    let
        events =
            payload.update.events

        playerId =
            payload.playerId

        newAnimation =
            Tilt.animationFromEvents playerId events

        drawn =
            Protocol.tokensMovedTo ("hand:" ++ playerId) events

        startAnimation =
            newAnimation /= Nothing

        updated =
            { model
                | payload = Just payload
                , playerId = Just playerId
                , legal = payload.update.legal
                , connectionStatus = Connected
                , newCardIds =
                    if List.isEmpty drawn then
                        model.newCardIds

                    else
                        Set.fromList drawn
                , currentAnimationData =
                    if startAnimation then
                        newAnimation

                    else
                        model.currentAnimationData
                , scoreAnimation =
                    if startAnimation then
                        { phase = OpponentBase, cardIndex = 0, nextStepTime = Nothing }

                    else
                        model.scoreAnimation
                , viewingResults = startAnimation || model.viewingResults
            }
    in
    ( refreshView updated, Task.perform ClockSynced Time.now )


currentClock : Model -> Maybe Protocol.Clock
currentClock model =
    model.payload |> Maybe.map (\p -> p.update.clock)


clockRunning : Model -> Bool
clockRunning model =
    case currentClock model of
        Just clock ->
            clock.enabled && List.any .running clock.players

        Nothing ->
            False


nameOf : Model -> String -> String
nameOf model playerId =
    model.payload
        |> Maybe.andThen (\p -> Protocol.findPlayer playerId p.update.scene)
        |> Maybe.map .name
        |> Maybe.withDefault playerId


{-| Rebuild the Tilt view from the latest payload. While a score reveal is
playing, the last playing-phase view stays on screen even if the server has
already moved on to the shop or the match summary.
-}
refreshView : Model -> Model
refreshView model =
    case model.payload of
        Nothing ->
            model

        Just payload ->
            if payload.game /= "tilt" then
                model

            else
                let
                    scene =
                        payload.update.scene

                    adapted =
                        Tilt.toPlayerView payload.playerId payload.rematchReady scene

                    withAnimation playing =
                        { playing
                            | pendingAnimation =
                                if model.viewingResults then
                                    model.currentAnimationData

                                else
                                    Nothing
                        }

                    lastPlaying =
                        case adapted of
                            Just (PlayingView playing) ->
                                Just playing

                            _ ->
                                model.lastPlaying

                    shown =
                        case adapted of
                            Just (PlayingView playing) ->
                                Just (PlayingView (withAnimation playing))

                            Just other ->
                                case ( model.viewingResults, model.lastPlaying ) of
                                    ( True, Just playing ) ->
                                        Just (PlayingView (withAnimation playing))

                                    _ ->
                                        Just other

                            Nothing ->
                                Nothing

                    shopUIState =
                        case shown of
                            Just (ShopView shopData) ->
                                Just (deriveShopUIStatePreservingSelections payload.playerId shopData.shopState model.shopUIState)

                            _ ->
                                Nothing
                in
                { model
                    | lastPlaying = lastPlaying
                    , shopUIState = shopUIState
                    , gameState =
                        case shown of
                            Just view_ ->
                                Success view_

                            Nothing ->
                                Failure "Could not read the game state"
                }



-- VIEW


view : Model -> Html Msg
view model =
    if model.gameSlug == "tilt" then
        Html.div []
            [ View.Game.viewGame model
            , Html.div [ Html.Attributes.class "fixed top-1 right-1 z-40 pointer-events-none" ]
                [ View.Clock.view
                    { clock = currentClock model
                    , playerId = Maybe.withDefault "" model.playerId
                    , receivedAt = model.clockReceivedAt
                    , now = model.nowMs
                    , nameOf = nameOf model
                    }
                ]
            ]

    else
        case model.payload of
            Just payload ->
                let
                    clockView =
                        View.Clock.view
                            { clock = Just payload.update.clock
                            , playerId = payload.playerId
                            , receivedAt = model.clockReceivedAt
                            , now = model.nowMs
                            , nameOf = nameOf model
                            }

                    finished =
                        case payload.update.outcome of
                            Protocol.Ongoing ->
                                Nothing

                            Protocol.Finished winners ->
                                Just winners
                in
                if model.gameSlug == "backgammon" then
                    Html.map BackgammonMsg
                        (Backgammon.view
                            { playerId = payload.playerId
                            , scene = payload.update.scene
                            , legal = payload.update.legal
                            , model = model.backgammon
                            , clock = clockView
                            , nameOf = nameOf model
                            , rematchReady = payload.rematchReady
                            , finished = finished
                            }
                        )

                else
                    Html.map GenericMsg
                        (Generic.View.view
                            { playerId = payload.playerId
                            , scene = payload.update.scene
                            , legal = payload.update.legal
                            , model = model.generic
                            , status =
                                case finished of
                                    Nothing ->
                                        "in progress"

                                    Just winners ->
                                        "finished: " ++ String.join ", " (List.map (nameOf model) winners)
                            , clock = clockView
                            }
                        )

            Nothing ->
                Html.text "Connecting..."
