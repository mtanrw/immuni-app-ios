// AnalyticsLogic.swift
// Copyright (C) 2020 Presidenza del Consiglio dei Ministri.
// Please refer to the AUTHORS file for more information.
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Extensions
import Hydra
import ImmuniExposureNotification
import Katana
import Models
import Networking
import Tempura

extension Logic {
  enum Analytics {}
}

extension Logic.Analytics {
  /// Performs the analytics logic and sends the analytics to the server if needed.
  ///
  /// -seeAlso: Traffic-Analysis Mitigation document
  struct SendOperationalInfoIfNeeded: AppSideEffect {
    let outcome: ExposureDetectionOutcome

    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let analyticsState = context.getState().analytics
      let now = context.dependencies.now()

      if Self.shouldSendOperationInfoWithExposure(outcome: self.outcome, state: analyticsState, now: now) {
        try context.awaitDispatch(StochasticallySendOperationalInfoWithExposure())
        try context.awaitDispatch(UpdateDummyTrafficOpportunityWindowIfCurrent())
      } else if Self.shouldSendOperationInfoWithoutExposure(outcome: self.outcome, state: analyticsState, now: now) {
        try context.awaitDispatch(StochasticallySendOperationalInfoWithoutExposure())
        try context.awaitDispatch(UpdateDummyTrafficOpportunityWindowIfCurrent())
      } else if Self.shouldSendDummyAnalytics(state: analyticsState, now: now) {
        try context.awaitDispatch(SendDummyAnalytics())
        try context.awaitDispatch(UpdateDummyTrafficOpportunityWindow())
      }

      // In any case, update the dummy traffic opportunity window if expired
      try context.awaitDispatch(UpdateDummyTrafficOpportunityWindowIfExpired())
    }

    /// Whether a genuine Operation Info With Exposure should be sent
    private static func shouldSendOperationInfoWithExposure(
      outcome: ExposureDetectionOutcome,
      state: AnalyticsState,
      now: Date
    ) -> Bool {
      guard case .fullDetection = outcome else {
        // Operational Info with Exposure only makes sense for a full detection
        return false
      }

      let lastSent = state.eventWithExposureLastSent
      let today = now.utcCalendarDay

      guard today.month != lastSent.month else {
        // Only one genuine Operational Info with Exposure per month is sent.
        // Note that the device's clock may be changed to alter this sequence, but the backend will rate limit the event
        // nonetheless
        return false
      }

      return true
    }

    /// Whether a genuine Operation Info Without Exposure should be sent
    private static func shouldSendOperationInfoWithoutExposure(
      outcome: ExposureDetectionOutcome,
      state: AnalyticsState,
      now: Date
    ) -> Bool {
      guard case .partialDetection = outcome else {
        // Operational Info without Exposure only makes sense for a partial detections.
        return false
      }

      let lastSent = state.eventWithoutExposureLastSent
      let today = now.utcCalendarDay

      guard today.month != lastSent.month else {
        // Only one genuine Operational Info without Exposure per month is sent
        // Note that the device's clock may be changed to alter this sequence, but the backend will rate limit the event
        // nonetheless
        return false
      }

      guard state.eventWithoutExposureWindow.contains(now) else {
        // The opportunity window is not open
        return false
      }

      return true
    }

    /// Whether a dummy analytics request should be sent
    private static func shouldSendDummyAnalytics(state: AnalyticsState, now: Date) -> Bool {
      guard state.dummyTrafficOpportunityWindow.contains(now) else {
        // The opportunity window is not open
        return false
      }

      return true
    }

    /// Whether a the opportunity window for the dummy traffic has expired
    private static func isDummyAnalyticsOpportunityWindowExpired(state: AnalyticsState, now: Date) -> Bool {
      guard now >= state.dummyTrafficOpportunityWindow.windowEnd else {
        // The current time does not fall after the end of the opportunity window
        return false
      }

      return true
    }
  }
}

// MARK: Operational Info with exposure

extension Logic.Analytics {
  /// Attempts to send an analytic event with a certain probability
  struct StochasticallySendOperationalInfoWithExposure: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let currentDay = context.dependencies.now().utcCalendarDay
      let state = context.getState()

      // the month is "immediately used" regardless of the checks done below
      try context.awaitDispatch(UpdateEventWithExposureLastSent(day: currentDay))

      let randomNumber = context.dependencies.uniformDistributionGenerator.randomNumberBetweenZeroAndOne()
      let samplingRate = state.configuration.operationalInfoWithExposureSamplingRate

      guard randomNumber < samplingRate else {
        // Avoid sending the request
        return
      }

      // Send the request
      try context.awaitDispatch(SendRequest(kind: .withExposure))
    }
  }
}

// MARK: Operational Info without exposure

extension Logic.Analytics {
  /// Attempts to send an analytic event with a certain probability
  struct StochasticallySendOperationalInfoWithoutExposure: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let now = context.dependencies.now()
      let currentDay = now.utcCalendarDay
      let state = context.getState()

      // the month is "immediately used" regardless of the checks done below
      try context.awaitDispatch(UpdateEventWithoutExposureLastSent(day: currentDay))

      let randomNumber = context.dependencies.uniformDistributionGenerator.randomNumberBetweenZeroAndOne()
      let samplingRate = state.configuration.operationalInfoWithoutExposureSamplingRate

      guard randomNumber < samplingRate else {
        // Avoid sending the request
        return
      }

      // Send the request
      try context.awaitDispatch(SendRequest(kind: .withoutExposure))
    }
  }

  /// Updates the event without exposure opportunity window if required
  struct UpdateEventWithoutExposureOpportunityWindowIfNeeded: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let state = context.getState()
      let now = context.dependencies.now()
      let currentMonth = now.utcCalendarMonth

      guard state.analytics.eventWithoutExposureWindow.month < currentMonth else {
        // the opportunity window refers to this month (or a future month, which
        // occurs just in case of changing the device's clock). We don't need to
        // perform any operation
        return
      }

      // we need to update the opportunity window
      let numDays = currentMonth.numberOfDays
      let maxShift = Double(numDays - 1) * OpportunityWindow.secondsInDay
      let shift = context.dependencies.uniformDistributionGenerator.random(in: 0 ..< maxShift)
      let opportunityWindow = OpportunityWindow(month: currentMonth, shift: shift)
      try context.awaitDispatch(SetEventWithoutExposureOpportunityWindow(window: opportunityWindow))
    }
  }
}

// MARK: Dummy traffic

extension Logic.Analytics {
  /// Sends a dummy analytics request to the backend
  struct SendDummyAnalytics: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      try context.awaitDispatch(SendRequest(kind: .dummy))
    }
  }

  struct UpdateDummyTrafficOpportunityWindowIfCurrent: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let state = context.getState()
      guard state.analytics.dummyTrafficOpportunityWindow.contains(context.dependencies.now()) else {
        // The dummy traffic opportunity is not currently open. Nothing to do
        return
      }

      try context.awaitDispatch(UpdateDummyTrafficOpportunityWindow())
    }
  }

  struct UpdateDummyTrafficOpportunityWindowIfExpired: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let state = context.getState()
      guard !state.analytics.dummyTrafficOpportunityWindow.contains(context.dependencies.now()) else {
        // The dummy traffic opportunity is currently open. Nothing to do
        return
      }

      try context.awaitDispatch(UpdateDummyTrafficOpportunityWindow())
    }
  }

  /// Updates the dummy analytics traffic opportunity window taking the parameters from the Configuration and the RNGs.
  struct UpdateDummyTrafficOpportunityWindow: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let state = context.getState()

      let dummyTrafficStochasticDelay = context.dependencies.exponentialDistributionGenerator
        .exponentialRandom(with: state.configuration.dummyAnalyticsMeanStochasticDelay)

      try context.awaitDispatch(
        SetDummyTrafficOpportunityWindow(
          dummyTrafficStochasticDelay: dummyTrafficStochasticDelay,
          now: context.dependencies.now()
        )
      )
    }
  }
}

// MARK: - Token management

extension Logic.Analytics {
  struct RefreshAnalyticsTokenIfExpired: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let state = context.getState()
      let now = context.dependencies.now()

      switch state.analytics.token {
      case .none:
        // No token
        try context.awaitDispatch(RefreshAnalyticsToken())
      case .validated(_, let expiration) where expiration > now:
        // Token not expired and validated
        return
      case .generated(let tokenString, let expiration) where expiration > now:
        // Token not expired but not validated
        try context.awaitDispatch(ValidateAnalyticsToken(token: tokenString, expiration: expiration))
      case .generated, .validated:
        // Token expired
        try context.awaitDispatch(RefreshAnalyticsToken())
      }
    }
  }

  struct RefreshAnalyticsToken: AppSideEffect {
    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      #warning("Ensure length is appropriate")
      let token = context.dependencies.analyticsTokenGenerator.generateToken(length: 168)
      let expiration = context.dependencies.analyticsTokenGenerator.nextExpirationDate()

      try context.awaitDispatch(SetAnalyticsToken(token: .generated(token: token, expiration: expiration)))
      try context.awaitDispatch(ValidateAnalyticsToken(token: token, expiration: expiration))
    }
  }

  struct ValidateAnalyticsToken: AppSideEffect {
    let token: String
    let expiration: Date

    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let dcToken = try await(context.dependencies.deviceTokenGenerator.generateToken())
      try await(context.dependencies.networkManager.validateAnalyticsToken(token: self.token, dcToken: dcToken))
      try context.awaitDispatch(SetAnalyticsToken(token: .validated(token: self.token, expiration: self.expiration)))
    }
  }
}

// MARK: Send Request

extension Logic.Analytics {
  struct SendRequest: AppSideEffect {
    /// The kind of request to send to the backend
    enum Kind {
      case withExposure
      case withoutExposure
      case dummy
    }

    let kind: Kind

    func sideEffect(_ context: SideEffectContext<AppState, AppDependencies>) throws {
      let state = context.getState()
      guard let userProvince = state.user.province else {
        // The onboarding is not done yet. Nothing should be sent.
        return
      }

      guard let token = state.analytics.token, token.isValid(now: context.dependencies.now()) else {
        // Not analytics token defined, or it is not valid. This is very unlikely.
        return
      }

      let userExposureNotificationStatus = state.environment.exposureNotificationAuthorizationStatus
      let userPushNotificationStatus = state.environment.pushNotificationAuthorizationStatus

      let body: AnalyticsRequest.Body
      let isDummy: Bool
      switch self.kind {
      case .withExposure:
        body = .init(
          province: userProvince,
          exposureNotificationStatus: userExposureNotificationStatus,
          pushNotificationStatus: userPushNotificationStatus,
          riskyExposureDetected: true,
          analyticsToken: token.token
        )
        isDummy = false
      case .withoutExposure:
        body = .init(
          province: userProvince,
          exposureNotificationStatus: userExposureNotificationStatus,
          pushNotificationStatus: userPushNotificationStatus,
          riskyExposureDetected: false,
          analyticsToken: token.token
        )
        isDummy = false
      case .dummy:
        body = .dummy(dummyToken: String.random(length: token.token.count))
        isDummy = true
      }

      // Await for the request to be fulfilled but catch errors silently
      _ = try? await(context.dependencies.networkManager.sendAnalytics(body: body, isDummy: isDummy))
    }
  }
}

// MARK: State Updaters

extension Logic.Analytics {
  /// Updates the date in which an analytic event with exposure has been sent
  struct UpdateEventWithExposureLastSent: AppStateUpdater {
    let day: CalendarDay

    func updateState(_ state: inout AppState) {
      state.analytics.eventWithExposureLastSent = self.day
    }
  }

  /// Updates the date in which an analytic event without exposure has been sent
  struct UpdateEventWithoutExposureLastSent: AppStateUpdater {
    let day: CalendarDay

    func updateState(_ state: inout AppState) {
      state.analytics.eventWithoutExposureLastSent = self.day
    }
  }

  /// Updates the opportunity window for the event without exposure
  struct SetEventWithoutExposureOpportunityWindow: AppStateUpdater {
    let window: OpportunityWindow

    func updateState(_ state: inout AppState) {
      state.analytics.eventWithoutExposureWindow = self.window
    }
  }

  /// Sets the opportunity window for the dummy analytics traffic
  struct SetDummyTrafficOpportunityWindow: AppStateUpdater {
    let dummyTrafficStochasticDelay: Double
    let now: Date

    func updateState(_ state: inout AppState) {
      let windowStart = self.now.addingTimeInterval(self.dummyTrafficStochasticDelay)
      let windowDuration = OpportunityWindow.secondsInDay
      state.analytics.dummyTrafficOpportunityWindow = .init(windowStart: windowStart, windowDuration: windowDuration)
    }
  }

  struct SetAnalyticsToken: AppStateUpdater {
    let token: AnalyticsState.AnalyticsToken

    func updateState(_ state: inout AppState) {
      state.analytics.token = self.token
    }
  }
}
