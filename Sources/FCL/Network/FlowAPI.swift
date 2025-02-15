//
//  File.swift
//  File
//
//  Created by lmcmz on 4/10/21.
//

import Combine
import Foundation

final class API {
    internal let defaultUserAgent = "Flow SWIFT SDK"
    internal var cancellables = Set<AnyCancellable>()

    enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
    }

    // TODO: Improve this
    internal var canContinue = true

    func fetchService(url: URL, method: HTTPMethod = .get, params: [String: String]? = [:], data: Data? = nil) -> AnyPublisher<AuthnResponse, Error> {
        guard let fullURL = buildURL(url: url, params: params) else {
            return Result.Publisher(FCLError.generic).eraseToAnyPublisher()
        }
        var request = URLRequest(url: fullURL)
        request.httpMethod = method.rawValue

        if let httpBody = data {
            request.httpBody = httpBody
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("application/json", forHTTPHeaderField: "Accept")
        }

        if let location = fcl.config.get(.location) {
            request.addValue(location, forHTTPHeaderField: "referer")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config).dataTaskPublisher(for: request)
            .map { $0.data }
            .decode(type: AuthnResponse.self, decoder: decoder)
            .eraseToAnyPublisher()
    }

    func execHttpPost(service: Service?, data: Data? = nil) -> Future<AuthnResponse, Error> {
        guard let ser = service, let url = ser.endpoint, let param = ser.params else {
            return Future { $0(.failure(FCLError.generic)) }
        }

        return execHttpPost(url: url, params: param, data: data)
    }

    func execHttpPost(url: URL, method: HTTPMethod = .post, params: [String: String]? = [:], data: Data? = nil) -> Future<AuthnResponse, Error> {
        return Future { promise in

            var configData: Data?
            if let baseConfig = try? BaseConfigRequest().toDictionary() {
                var body: [String: Any]? = [:]
                if let data = data {
                    body = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                }

                let configDict = baseConfig.merging(body ?? [:]) { _, new in new }
                configData = try? JSONSerialization.data(withJSONObject: configDict)
            }

            self.fetchService(url: url, method: method, params: params, data: configData ?? data)
                .sink { completion in
                    if case let .failure(error) = completion {
                        print(error)
                    }
                } receiveValue: { result in
                    switch result.status {
                    case .approved:
                        promise(.success(result))
                    case .declined:
                        promise(.failure(FCLError.declined))
                    case .pending:
                        self.canContinue = true
                        guard let local = result.local,
                              let updates = result.updates ?? result.authorizationUpdates
                        else {
                            promise(.failure(FCLError.generic))
                            return
                        }
                        do {
                            try fcl.openAuthenticationSession(service: local)
                        } catch {
                            promise(.failure(error))
                        }

                        self.poll(service: updates) { result in
                            switch result {
                            case let .success(response):
                                promise(.success(response))
                            case let .failure(error):
                                promise(.failure(error))
                            }
                        }
                    }
                }.store(in: &self.cancellables)
        }
    }

    private func poll(service: Service, completion: @escaping (Result<AuthnResponse, Error>) -> Void) {
        if !canContinue {
            completion(Result.failure(FCLError.declined))
            return
        }

        guard let url = service.endpoint else {
            completion(Result.failure(FCLError.invaildURL))
            return
        }

        fetchService(url: url, method: .get, params: service.params)
            .sink { complete in
                if case let .failure(error) = complete {
                    completion(Result<AuthnResponse, Error>.failure(error))
                }

            } receiveValue: { result in
                switch result.status {
                case .approved:
                    fcl.closeSession()
                    SafariWebViewManager.dismiss()
                    completion(Result<AuthnResponse, Error>.success(result))
                case .declined:
                    fcl.closeSession()
                    SafariWebViewManager.dismiss()
                    completion(Result.failure(FCLError.declined))
                case .pending:
                    // TODO: Improve this
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) {
                        self.poll(service: service) { response in
                            completion(response)
                        }
                    }
                }
            }.store(in: &cancellables)
    }

    func buildURL(url: URL, params: [String: String]?) -> URL? {
        let paramLocation = "l6n"
        guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems: [URLQueryItem] = []

        if let location = fcl.config.get(.location) {
            queryItems.append(URLQueryItem(name: paramLocation, value: location))
        }

        for (name, value) in params ?? [:] {
            if name != paramLocation {
                queryItems.append(
                    URLQueryItem(name: name, value: value)
                )
            }
        }

        urlComponents.queryItems = queryItems
        return urlComponents.url
    }
}
