module Pages.Internal.Platform.Cli exposing
    ( Content
    , Effect(..)
    , Flags
    , Model
    , Msg(..)
    , Page
    , ToJsPayload(..)
    , ToJsSuccessPayload
    , cliApplication
    , init
    , toJsCodec
    , update
    )

import BuildError exposing (BuildError)
import Codec exposing (Codec)
import Dict exposing (Dict)
import Dict.Extra
import Head
import Html exposing (Html)
import Http
import Json.Decode as Decode
import Json.Encode
import Pages.ContentCache as ContentCache exposing (ContentCache)
import Pages.Document
import Pages.ImagePath as ImagePath
import Pages.Manifest as Manifest
import Pages.PagePath as PagePath exposing (PagePath)
import Pages.StaticHttp as StaticHttp exposing (RequestDetails)
import Pages.StaticHttp.Request as HashRequest
import Pages.StaticHttpRequest as StaticHttpRequest
import Secrets
import SecretsDict exposing (SecretsDict)
import Set exposing (Set)
import TerminalText as Terminal


type ToJsPayload pathKey
    = Errors String
    | Success (ToJsSuccessPayload pathKey)


type alias ToJsSuccessPayload pathKey =
    { pages : Dict String (Dict String String)
    , manifest : Manifest.Config pathKey
    , filesToGenerate : List FileToGenerate
    , errors : List String
    }


type alias FileToGenerate =
    { path : List String
    , content : String
    }


toJsCodec : Codec (ToJsPayload pathKey)
toJsCodec =
    Codec.custom
        (\errorsTag success value ->
            case value of
                Errors errorList ->
                    errorsTag errorList

                Success { pages, manifest, filesToGenerate, errors } ->
                    success (ToJsSuccessPayload pages manifest filesToGenerate errors)
        )
        |> Codec.variant1 "Errors" Errors Codec.string
        |> Codec.variant1 "Success"
            Success
            successCodec
        |> Codec.buildCustom


stubManifest : Manifest.Config pathKey
stubManifest =
    { backgroundColor = Nothing
    , categories = []
    , displayMode = Manifest.Standalone
    , orientation = Manifest.Portrait
    , description = "elm-pages - A statically typed site generator."
    , iarcRatingId = Nothing
    , name = "elm-pages docs"
    , themeColor = Nothing
    , startUrl = PagePath.external ""
    , shortName = Just "elm-pages"
    , sourceIcon = ImagePath.external ""
    }


successCodec : Codec (ToJsSuccessPayload pathKey)
successCodec =
    Codec.object ToJsSuccessPayload
        |> Codec.field "pages"
            .pages
            (Codec.dict (Codec.dict Codec.string))
        |> Codec.field "manifest"
            .manifest
            (Codec.build Manifest.toJson (Decode.succeed stubManifest))
        |> Codec.field "filesToGenerate"
            .filesToGenerate
            (Codec.build
                (\list ->
                    list
                        |> Json.Encode.list
                            (\item ->
                                Json.Encode.object
                                    [ ( "path", item.path |> String.join "/" |> Json.Encode.string )
                                    , ( "content", item.content |> Json.Encode.string )
                                    ]
                            )
                )
                (Decode.succeed [])
            )
        |> Codec.field "errors" .errors (Codec.list Codec.string)
        |> Codec.buildObject


type Effect pathKey
    = NoEffect
    | SendJsData (ToJsPayload pathKey)
    | FetchHttp { masked : RequestDetails, unmasked : RequestDetails }
    | Batch (List (Effect pathKey))


type alias Page metadata view pathKey =
    { metadata : metadata
    , path : PagePath pathKey
    , view : view
    }


type alias Content =
    List ( List String, { extension : String, frontMatter : String, body : Maybe String } )


type alias Flags =
    Decode.Value


type alias Model =
    { staticResponses : StaticResponses
    , secrets : SecretsDict
    , errors : List BuildError
    , allRawResponses : Dict String (Maybe String)
    , mode : Mode
    }


type Msg
    = GotStaticHttpResponse { request : { masked : RequestDetails, unmasked : RequestDetails }, response : Result Http.Error String }


type alias Config pathKey userMsg userModel metadata view =
    { init :
        Maybe
            { path : PagePath pathKey
            , query : Maybe String
            , fragment : Maybe String
            }
        -> ( userModel, Cmd userMsg )
    , update : userMsg -> userModel -> ( userModel, Cmd userMsg )
    , subscriptions : userModel -> Sub userMsg
    , view :
        List ( PagePath pathKey, metadata )
        ->
            { path : PagePath pathKey
            , frontmatter : metadata
            }
        ->
            StaticHttp.Request
                { view : userModel -> view -> { title : String, body : Html userMsg }
                , head : List (Head.Tag pathKey)
                }
    , document : Pages.Document.Document metadata view
    , content : Content
    , toJsPort : Json.Encode.Value -> Cmd Never
    , manifest : Manifest.Config pathKey
    , generateFiles :
        List
            { path : PagePath pathKey
            , frontmatter : metadata
            , body : String
            }
        ->
            List
                (Result String
                    { path : List String
                    , content : String
                    }
                )
    , canonicalSiteUrl : String
    , pathKey : pathKey
    , onPageChange :
        { path : PagePath pathKey
        , query : Maybe String
        , fragment : Maybe String
        }
        -> userMsg
    }


cliApplication :
    (Msg -> msg)
    -> (msg -> Maybe Msg)
    -> (Model -> model)
    -> (model -> Maybe Model)
    -> Config pathKey userMsg userModel metadata view
    -> Platform.Program Flags model msg
cliApplication cliMsgConstructor narrowMsg toModel fromModel config =
    let
        contentCache =
            ContentCache.init config.document config.content Nothing

        siteMetadata =
            contentCache
                |> Result.map
                    (\cache -> cache |> ContentCache.extractMetadata config.pathKey)
                |> Result.mapError (List.map Tuple.second)
    in
    Platform.worker
        { init =
            \flags ->
                init toModel contentCache siteMetadata config flags
                    |> Tuple.mapSecond (perform cliMsgConstructor config.toJsPort)
        , update =
            \msg model ->
                case ( narrowMsg msg, fromModel model ) of
                    ( Just cliMsg, Just cliModel ) ->
                        update siteMetadata config cliMsg cliModel
                            |> Tuple.mapSecond (perform cliMsgConstructor config.toJsPort)
                            |> Tuple.mapFirst toModel

                    _ ->
                        ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


type Mode
    = Prod
    | Dev


modeDecoder =
    Decode.string
        |> Decode.andThen
            (\mode ->
                if mode == "prod" then
                    Decode.succeed Prod

                else
                    Decode.succeed Dev
            )


perform : (Msg -> msg) -> (Json.Encode.Value -> Cmd Never) -> Effect pathKey -> Cmd msg
perform cliMsgConstructor toJsPort effect =
    case effect of
        NoEffect ->
            Cmd.none

        SendJsData value ->
            value
                |> Codec.encoder toJsCodec
                |> toJsPort
                |> Cmd.map never

        Batch list ->
            list
                |> List.map (perform cliMsgConstructor toJsPort)
                |> Cmd.batch

        FetchHttp ({ unmasked, masked } as requests) ->
            --let
            --    _ =
            --        Debug.log "Fetching" masked.url
            --in
            Http.request
                { method = unmasked.method
                , url = unmasked.url
                , headers = unmasked.headers |> List.map (\( key, value ) -> Http.header key value)
                , body = Http.emptyBody
                , expect =
                    Http.expectString
                        (\response ->
                            (GotStaticHttpResponse >> cliMsgConstructor)
                                { request = requests
                                , response = response
                                }
                        )
                , timeout = Nothing
                , tracker = Nothing
                }


init :
    (Model -> model)
    -> ContentCache.ContentCache metadata view
    -> Result (List BuildError) (List ( PagePath pathKey, metadata ))
    -> Config pathKey userMsg userModel metadata view
    -> Decode.Value
    -> ( model, Effect pathKey )
init toModel contentCache siteMetadata config flags =
    case
        Decode.decodeValue
            (Decode.map2 Tuple.pair
                (Decode.field "secrets" SecretsDict.decoder)
                (Decode.field "mode" modeDecoder)
            )
            flags
    of
        Ok ( secrets, mode ) ->
            case contentCache of
                Ok _ ->
                    case contentCache |> ContentCache.pagesWithErrors of
                        [] ->
                            let
                                requests =
                                    siteMetadata
                                        |> Result.andThen
                                            (\metadata ->
                                                staticResponseForPage metadata config.view
                                            )

                                staticResponses : StaticResponses
                                staticResponses =
                                    case requests of
                                        Ok okRequests ->
                                            staticResponsesInit okRequests

                                        Err errors ->
                                            -- TODO need to handle errors better?
                                            staticResponsesInit []

                                ( updatedRawResponses, effect ) =
                                    sendStaticResponsesIfDone config siteMetadata mode secrets Dict.empty [] staticResponses
                            in
                            ( Model staticResponses secrets [] updatedRawResponses mode |> toModel
                            , effect
                            )

                        pageErrors ->
                            let
                                requests =
                                    siteMetadata
                                        |> Result.andThen
                                            (\metadata ->
                                                staticResponseForPage metadata config.view
                                            )

                                staticResponses : StaticResponses
                                staticResponses =
                                    case requests of
                                        Ok okRequests ->
                                            staticResponsesInit okRequests

                                        Err errors ->
                                            -- TODO need to handle errors better?
                                            staticResponsesInit []
                            in
                            updateAndSendPortIfDone
                                config
                                siteMetadata
                                (Model
                                    staticResponses
                                    secrets
                                    pageErrors
                                    Dict.empty
                                    mode
                                )
                                toModel

                Err metadataParserErrors ->
                    updateAndSendPortIfDone
                        config
                        siteMetadata
                        (Model Dict.empty
                            secrets
                            (metadataParserErrors |> List.map Tuple.second)
                            Dict.empty
                            mode
                        )
                        toModel

        Err error ->
            updateAndSendPortIfDone
                config
                siteMetadata
                (Model Dict.empty
                    SecretsDict.masked
                    [ { title = "Internal Error"
                      , message = [ Terminal.text <| "Failed to parse flags: " ++ Decode.errorToString error ]
                      , fatal = True
                      }
                    ]
                    Dict.empty
                    Dev
                )
                toModel


updateAndSendPortIfDone :
    Config pathKey userMsg userModel metadata view
    -> Result (List BuildError) (List ( PagePath pathKey, metadata ))
    -> Model
    -> (Model -> model)
    -> ( model, Effect pathKey )
updateAndSendPortIfDone config siteMetadata model toModel =
    let
        ( updatedAllRawResponses, effect ) =
            sendStaticResponsesIfDone
                config
                siteMetadata
                model.mode
                model.secrets
                model.allRawResponses
                model.errors
                model.staticResponses
    in
    ( { model | allRawResponses = updatedAllRawResponses } |> toModel
    , effect
    )


type alias PageErrors =
    Dict String String


update :
    Result (List BuildError) (List ( PagePath pathKey, metadata ))
    -> Config pathKey userMsg userModel metadata view
    -> Msg
    -> Model
    -> ( Model, Effect pathKey )
update siteMetadata config msg model =
    case msg of
        GotStaticHttpResponse { request, response } ->
            let
                --_ =
                --    Debug.log "Got response" request.masked.url
                --
                updatedModel =
                    (case response of
                        Ok okResponse ->
                            staticResponsesUpdate
                                { request = request
                                , response =
                                    response |> Result.mapError (\_ -> ())
                                }
                                model

                        Err error ->
                            { model
                                | errors =
                                    model.errors
                                        ++ [ { title = "Static HTTP Error"
                                             , message =
                                                [ Terminal.text "I got an error making an HTTP request to this URL: "

                                                -- TODO include HTTP method, headers, and body
                                                , Terminal.yellow <| Terminal.text request.masked.url
                                                , Terminal.text "\n\n"
                                                , case error of
                                                    Http.BadStatus code ->
                                                        Terminal.text <| "Bad status: " ++ String.fromInt code

                                                    Http.BadUrl _ ->
                                                        -- TODO include HTTP method, headers, and body
                                                        Terminal.text <| "Invalid url: " ++ request.masked.url

                                                    Http.Timeout ->
                                                        Terminal.text "Timeout"

                                                    Http.NetworkError ->
                                                        Terminal.text "Network error"

                                                    Http.BadBody string ->
                                                        Terminal.text "Unable to parse HTTP response body"
                                                ]
                                             , fatal = True
                                             }
                                           ]
                            }
                    )
                        |> staticResponsesUpdate
                            -- TODO for hash pass in RequestDetails here
                            { request = request
                            , response =
                                response |> Result.mapError (\_ -> ())
                            }

                ( updatedAllRawResponses, effect ) =
                    sendStaticResponsesIfDone config siteMetadata updatedModel.mode updatedModel.secrets updatedModel.allRawResponses updatedModel.errors updatedModel.staticResponses
            in
            ( { updatedModel | allRawResponses = updatedAllRawResponses }
            , effect
            )


dictCompact : Dict String (Maybe a) -> Dict String a
dictCompact dict =
    dict
        |> Dict.Extra.filterMap (\key value -> value)


performStaticHttpRequests : Dict String (Maybe String) -> SecretsDict -> List ( String, StaticHttp.Request a ) -> Result (List BuildError) (List { unmasked : RequestDetails, masked : RequestDetails })
performStaticHttpRequests allRawResponses secrets staticRequests =
    staticRequests
        |> List.map
            (\( pagePath, request ) ->
                StaticHttpRequest.resolveUrls request
                    (allRawResponses
                        |> dictCompact
                    )
                    |> Tuple.second
            )
        |> List.concat
        -- TODO prevent duplicates... can't because Set needs comparable
        --        |> Set.fromList
        --        |> Set.toList
        |> List.map
            (\urlBuilder ->
                Secrets.lookup secrets urlBuilder
                    |> Result.map
                        (\unmasked ->
                            { unmasked = unmasked, masked = Secrets.maskedLookup urlBuilder }
                        )
            )
        |> combineMultipleErrors
        |> Result.mapError List.concat


combineMultipleErrors : List (Result error a) -> Result (List error) (List a)
combineMultipleErrors results =
    List.foldr
        (\result soFarResult ->
            case soFarResult of
                Ok soFarOk ->
                    case result of
                        Ok value ->
                            value :: soFarOk |> Ok

                        Err error ->
                            Err [ error ]

                Err errorsSoFar ->
                    case result of
                        Ok _ ->
                            Err errorsSoFar

                        Err error ->
                            Err <| error :: errorsSoFar
        )
        (Ok [])
        results


staticResponsesInit : List ( PagePath pathKey, StaticHttp.Request value ) -> StaticResponses
staticResponsesInit list =
    list
        |> List.map
            (\( path, staticRequest ) ->
                ( PagePath.toString path
                , NotFetched (staticRequest |> StaticHttp.map (\_ -> ())) Dict.empty
                )
            )
        |> Dict.fromList


staticResponsesUpdate : { request : { masked : RequestDetails, unmasked : RequestDetails }, response : Result () String } -> Model -> Model
staticResponsesUpdate newEntry model =
    let
        updatedAllResponses =
            model.allRawResponses
                -- @@@@@@@@@ TODO handle errors here, change Dict to have `Result` instead of `Maybe`
                |> Dict.insert (HashRequest.hash newEntry.request.masked) (Just (newEntry.response |> Result.withDefault "TODO"))
    in
    { model
        | allRawResponses = updatedAllResponses
        , staticResponses =
            model.staticResponses
                |> Dict.map
                    (\pageUrl entry ->
                        case entry of
                            NotFetched request rawResponses ->
                                let
                                    realUrls =
                                        StaticHttpRequest.resolveUrls request
                                            (updatedAllResponses |> dictCompact)
                                            |> Tuple.second
                                            |> List.map Secrets.maskedLookup
                                            |> List.map HashRequest.hash

                                    includesUrl =
                                        List.member (HashRequest.hash newEntry.request.masked)
                                            realUrls
                                in
                                if includesUrl then
                                    let
                                        updatedRawResponses =
                                            rawResponses
                                                |> Dict.insert (HashRequest.hash newEntry.request.masked) newEntry.response
                                    in
                                    NotFetched request updatedRawResponses

                                else
                                    entry
                    )
    }


isJust : Maybe a -> Bool
isJust maybeValue =
    case maybeValue of
        Just _ ->
            True

        Nothing ->
            False


sendStaticResponsesIfDone :
    Config pathKey userMsg userModel metadata view
    -> Result (List BuildError) (List ( PagePath pathKey, metadata ))
    -> Mode
    -> SecretsDict
    -> Dict String (Maybe String)
    -> List BuildError
    -> StaticResponses
    -> ( Dict String (Maybe String), Effect pathKey )
sendStaticResponsesIfDone config siteMetadata mode secrets allRawResponses errors staticResponses =
    let
        pendingRequests =
            staticResponses
                |> Dict.Extra.any
                    (\path entry ->
                        case entry of
                            NotFetched request rawResponses ->
                                let
                                    usableRawResponses : Dict String String
                                    usableRawResponses =
                                        rawResponses
                                            |> Dict.Extra.filterMap
                                                (\key value ->
                                                    value
                                                        |> Result.map Just
                                                        |> Result.withDefault Nothing
                                                )

                                    hasPermanentError =
                                        StaticHttpRequest.permanentError request usableRawResponses
                                            |> isJust

                                    hasPermanentHttpError =
                                        not <| List.isEmpty errors

                                    --|> List.any
                                    --    (\error ->
                                    --        case error of
                                    --            FailedStaticHttpRequestError _ ->
                                    --                True
                                    --
                                    --            _ ->
                                    --                False
                                    --    )
                                    ( allUrlsKnown, knownUrlsToFetch ) =
                                        StaticHttpRequest.resolveUrls request
                                            (rawResponses |> Dict.map (\key value -> value |> Result.withDefault ""))

                                    fetchedAllKnownUrls =
                                        (knownUrlsToFetch
                                            |> List.map Secrets.maskedLookup
                                            |> List.map HashRequest.hash
                                            |> Set.fromList
                                            |> Set.size
                                        )
                                            == (rawResponses |> Dict.keys |> List.length)
                                in
                                if hasPermanentHttpError || hasPermanentError || (allUrlsKnown && fetchedAllKnownUrls) then
                                    False

                                else
                                    True
                    )

        failedRequests =
            staticResponses
                |> Dict.toList
                |> List.concatMap
                    (\( path, NotFetched request rawResponses ) ->
                        let
                            usableRawResponses : Dict String String
                            usableRawResponses =
                                rawResponses
                                    |> Dict.Extra.filterMap
                                        (\key value ->
                                            value
                                                |> Result.map Just
                                                |> Result.withDefault Nothing
                                        )

                            maybePermanentError =
                                StaticHttpRequest.permanentError request
                                    usableRawResponses

                            decoderErrors =
                                maybePermanentError
                                    |> Maybe.map (StaticHttpRequest.toBuildError path)
                                    |> Maybe.map List.singleton
                                    |> Maybe.withDefault []
                        in
                        decoderErrors
                    )
    in
    if pendingRequests then
        let
            requestContinuations : List ( String, StaticHttp.Request () )
            requestContinuations =
                staticResponses
                    |> Dict.toList
                    |> List.map
                        (\( path, NotFetched request rawResponses ) ->
                            ( path, request )
                        )

            ( updatedAllRawResponses, newEffect ) =
                case
                    performStaticHttpRequests allRawResponses secrets requestContinuations
                of
                    Ok urlsToPerform ->
                        let
                            newAllRawResponses =
                                Dict.union allRawResponses dictOfNewUrlsToPerform

                            dictOfNewUrlsToPerform =
                                urlsToPerform
                                    |> List.map .masked
                                    |> List.map HashRequest.hash
                                    |> List.map (\hashedUrl -> ( hashedUrl, Nothing ))
                                    |> Dict.fromList

                            maskedToUnmasked : Dict String { masked : RequestDetails, unmasked : RequestDetails }
                            maskedToUnmasked =
                                urlsToPerform
                                    --                                    |> List.map (\secureUrl -> ( Pages.Internal.Secrets.masked secureUrl, secureUrl ))
                                    |> List.map
                                        (\secureUrl ->
                                            --                                            ( hashUrl secureUrl, { unmasked = secureUrl, masked = secureUrl } )
                                            ( HashRequest.hash secureUrl.masked, secureUrl )
                                        )
                                    |> Dict.fromList

                            alreadyPerformed =
                                allRawResponses
                                    |> Dict.keys
                                    |> Set.fromList

                            newThing =
                                maskedToUnmasked
                                    |> Dict.Extra.removeMany alreadyPerformed
                                    |> Dict.toList
                                    |> List.map
                                        (\( maskedUrl, secureUrl ) ->
                                            FetchHttp secureUrl
                                        )
                                    |> Batch
                        in
                        ( newAllRawResponses, newThing )

                    Err error ->
                        ( allRawResponses
                        , SendJsData <|
                            (Errors <| BuildError.errorsToString (error ++ failedRequests ++ errors))
                        )
        in
        ( updatedAllRawResponses, newEffect )

    else
        let
            updatedAllRawResponses =
                Dict.empty

            generatedFiles =
                siteMetadata
                    |> Result.withDefault []
                    |> List.map
                        (\( pagePath, metadata ) ->
                            let
                                contentForPage =
                                    config.content
                                        |> List.filterMap
                                            (\( path, { body } ) ->
                                                let
                                                    pagePathToGenerate =
                                                        PagePath.toString pagePath

                                                    currentContentPath =
                                                        "/" ++ (path |> String.join "/")
                                                in
                                                if pagePathToGenerate == currentContentPath then
                                                    Just body

                                                else
                                                    Nothing
                                            )
                                        |> List.head
                                        |> Maybe.andThen identity
                            in
                            { path = pagePath
                            , frontmatter = metadata
                            , body = contentForPage |> Maybe.withDefault ""
                            }
                        )
                    |> config.generateFiles

            generatedOkayFiles =
                generatedFiles
                    |> List.filterMap
                        (\result ->
                            case result of
                                Ok ok ->
                                    Just ok

                                _ ->
                                    Nothing
                        )

            generatedFileErrors =
                generatedFiles
                    |> List.filterMap
                        (\result ->
                            case result of
                                Ok ok ->
                                    Nothing

                                Err error ->
                                    Just
                                        { title = "Generate Files Error"
                                        , message =
                                            [ Terminal.text "I encountered an Err from your generateFiles function. Message:\n"
                                            , Terminal.text <| "Error: " ++ error
                                            ]
                                        , fatal = True
                                        }
                        )

            allErrors : List BuildError
            allErrors =
                errors ++ failedRequests ++ generatedFileErrors
        in
        ( updatedAllRawResponses
        , toJsPayload
            (encodeStaticResponses mode staticResponses)
            config.manifest
            generatedOkayFiles
            allErrors
        )


toJsPayload encodedStatic manifest generated allErrors =
    SendJsData <|
        if allErrors |> List.filter .fatal |> List.isEmpty then
            Success
                (ToJsSuccessPayload
                    encodedStatic
                    manifest
                    generated
                    (List.map BuildError.errorToString allErrors)
                )

        else
            Errors <| BuildError.errorsToString allErrors


encodeStaticResponses : Mode -> StaticResponses -> Dict String (Dict String String)
encodeStaticResponses mode staticResponses =
    staticResponses
        |> Dict.map
            (\path result ->
                case result of
                    NotFetched request rawResponsesDict ->
                        let
                            relevantResponses =
                                rawResponsesDict
                                    |> Dict.map
                                        (\key value ->
                                            value
                                                -- TODO avoid running this code at all if there are errors here
                                                |> Result.withDefault ""
                                        )

                            strippedResponses : Dict String String
                            strippedResponses =
                                -- TODO should this return an Err and handle that here?
                                StaticHttpRequest.strippedResponses request relevantResponses
                        in
                        case mode of
                            Dev ->
                                relevantResponses

                            Prod ->
                                strippedResponses
            )


type alias StaticResponses =
    Dict String StaticHttpResult


type StaticHttpResult
    = NotFetched (StaticHttpRequest.Request ()) (Dict String (Result () String))


staticResponseForPage :
    List ( PagePath pathKey, metadata )
    ->
        (List ( PagePath pathKey, metadata )
         ->
            { path : PagePath pathKey
            , frontmatter : metadata
            }
         ->
            StaticHttpRequest.Request
                { view : userModel -> view -> { title : String, body : Html userMsg }
                , head : List (Head.Tag pathKey)
                }
        )
    ->
        Result (List BuildError)
            (List
                ( PagePath pathKey
                , StaticHttp.Request
                    { view : userModel -> view -> { title : String, body : Html userMsg }
                    , head : List (Head.Tag pathKey)
                    }
                )
            )
staticResponseForPage siteMetadata viewFn =
    siteMetadata
        |> List.map
            (\( pagePath, frontmatter ) ->
                let
                    thing =
                        viewFn siteMetadata
                            { path = pagePath
                            , frontmatter = frontmatter
                            }
                in
                Ok ( pagePath, thing )
            )
        |> combine


combine : List (Result error ( key, success )) -> Result (List error) (List ( key, success ))
combine list =
    list
        |> List.foldr resultFolder (Ok [])


resultFolder : Result error a -> Result (List error) (List a) -> Result (List error) (List a)
resultFolder current soFarResult =
    case soFarResult of
        Ok soFarOk ->
            case current of
                Ok currentOk ->
                    currentOk
                        :: soFarOk
                        |> Ok

                Err error ->
                    Err [ error ]

        Err soFarErr ->
            case current of
                Ok currentOk ->
                    Err soFarErr

                Err error ->
                    error
                        :: soFarErr
                        |> Err
