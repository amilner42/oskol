port module Main exposing (main)

import Browser
import Decoders exposing (..)
import Dict
import Encoders exposing (..)
import Html exposing (Html)
import Json.Decode as D
import Json.Encode as E
import Set exposing (Set)
import Types exposing (..)
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



-- FLAGS


type alias Flags =
    { gameId : String
    , playerId : Maybe String
    }



-- MODEL


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( { gameId = flags.gameId
      , playerId = flags.playerId
      , gameState = Loading
      , viewingModal = Nothing
      , selectedCards = Set.empty
      , newCardIds = Set.empty
      , acknowledgedEventSeq = 0
      , connectionStatus = Connecting
      , cardSort = ByRank
      }
    , Cmd.none
    )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ReceivedGameState gameState ->
            -- Initial game state received when joining channel
            ( { model
                | gameState = Success gameState
                , connectionStatus = Connected
              }
            , Cmd.none
            )

        GameStateUpdated gameState ->
            -- Game state update from server broadcast
            ( { model | gameState = Success gameState }
            , Cmd.none
            )

        ChannelError err ->
            ( { model | gameState = Failure err }
            , Cmd.none
            )

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
            case model.gameState of
                Success gameState ->
                    case getCurrentPlayer model of
                        Just currentPlayer ->
                            let
                                selectedCardsList =
                                    currentPlayer.cardPiles.handPile
                                        |> List.filter (\card -> Set.member card.id model.selectedCards)
                            in
                            ( { model
                                | selectedCards = Set.empty
                                , newCardIds = Set.empty
                              }
                            , sendToChannel (encodeLockInHand selectedCardsList)
                            )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        DiscardCards cardIds ->
            case model.gameState of
                Success gameState ->
                    case getCurrentPlayer model of
                        Just currentPlayer ->
                            let
                                cardsToDiscard =
                                    currentPlayer.cardPiles.handPile
                                        |> List.filter (\card -> List.member card.id cardIds)
                            in
                            ( { model
                                | selectedCards = Set.empty
                                , newCardIds = Set.empty
                              }
                            , sendToChannel (encodeDiscardCards cardsToDiscard)
                            )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        MakeShopPick cardIndex ->
            ( model
            , sendToChannel (encodeMakeShopPick cardIndex)
            )

        ConfirmDeckBuilder cardIndex ->
            ( model
            , sendToChannel (encodeConfirmDeckBuilder cardIndex)
            )

        CompleteDeckBuilderSelection cardIds ->
            ( model
            , sendToChannel (encodeCompleteDeckBuilderSelection cardIds)
            )

        SkipDeckBuilderSelection ->
            ( model
            , sendToChannel encodeSkipDeckBuilderSelection
            )

        ConfirmPlusBomb cardIndex ->
            ( model
            , sendToChannel (encodeConfirmPlusBomb cardIndex)
            )

        CompletePlusBombSelection cardId ->
            ( model
            , sendToChannel (encodeCompletePlusBombSelection cardId)
            )

        DestroyShopCard cardIndex ->
            ( model
            , sendToChannel (encodeDestroyShopCard cardIndex)
            )

        CompleteDestroyPhase ->
            ( model
            , sendToChannel encodeCompleteDestroyPhase
            )

        ReadyForNextRound ->
            ( model
            , sendToChannel encodeReadyForNextRound
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

        NoOp ->
            ( model, Cmd.none )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    receiveFromChannel handleChannelMessage


{-| Handle messages from the Phoenix channel
-}
handleChannelMessage : E.Value -> Msg
handleChannelMessage value =
    case D.decodeValue channelMessageDecoder value of
        Ok channelMsg ->
            case channelMsg of
                InitialGameState gameState ->
                    ReceivedGameState gameState

                GameUpdate gameState ->
                    GameStateUpdated gameState

                StatusUpdate status ->
                    ConnectionStatusChanged status

                Error err ->
                    ChannelError err

        Err err ->
            ChannelError (D.errorToString err)


{-| Decoder for channel messages
-}
type ChannelMessage
    = InitialGameState GameState
    | GameUpdate GameState
    | StatusUpdate ConnectionStatus
    | Error String


channelMessageDecoder : D.Decoder ChannelMessage
channelMessageDecoder =
    D.field "type" D.string
        |> D.andThen
            (\msgType ->
                case msgType of
                    "initial_state" ->
                        D.map InitialGameState (D.field "game_state" gameStateDecoder)

                    "game_state_updated" ->
                        D.map GameUpdate (D.field "game_state" gameStateDecoder)

                    "connection_status" ->
                        D.map StatusUpdate (D.field "status" connectionStatusDecoder)

                    "error" ->
                        D.map Error (D.field "message" D.string)

                    _ ->
                        D.fail ("Unknown message type: " ++ msgType)
            )


connectionStatusDecoder : D.Decoder ConnectionStatus
connectionStatusDecoder =
    D.string
        |> D.andThen
            (\str ->
                case str of
                    "disconnected" ->
                        D.succeed Disconnected

                    "connecting" ->
                        D.succeed Connecting

                    "connected" ->
                        D.succeed Connected

                    _ ->
                        D.fail ("Unknown connection status: " ++ str)
            )



-- VIEW


view : Model -> Html Msg
view model =
    View.Game.viewGame model
