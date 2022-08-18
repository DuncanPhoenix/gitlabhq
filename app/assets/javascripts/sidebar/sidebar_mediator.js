import Store from '~/sidebar/stores/sidebar_store';
import createFlash from '~/flash';
import { __ } from '~/locale';
import toast from '~/vue_shared/plugins/global_toast';
import { visitUrl } from '../lib/utils/url_utility';
import Service from './services/sidebar_service';

export default class SidebarMediator {
  constructor(options) {
    if (!SidebarMediator.singleton) {
      this.initSingleton(options);
    }

    // eslint-disable-next-line no-constructor-return
    return SidebarMediator.singleton;
  }

  initSingleton(options) {
    this.store = new Store(options);
    this.service = new Service({
      endpoint: options.endpoint,
      moveIssueEndpoint: options.moveIssueEndpoint,
      projectsAutocompleteEndpoint: options.projectsAutocompleteEndpoint,
      fullPath: options.fullPath,
      iid: options.iid,
      issuableType: options.issuableType,
    });
    SidebarMediator.singleton = this;
  }

  assignYourself() {
    this.store.addAssignee(this.store.currentUser);
  }

  async saveAssignees(field) {
    const selected = this.store.assignees.map((u) => u.id);

    // If there are no ids, that means we have to unassign (which is id = 0)
    // And it only accepts an array, hence [0]
    const assignees = selected.length === 0 ? [0] : selected;
    const data = { assignee_ids: assignees };

    try {
      const res = await this.service.update(field, data);

      this.store.overwrite('assignees', res.data.assignees);

      if (res.data.reviewers) {
        this.store.overwrite('reviewers', res.data.reviewers);
      }

      return Promise.resolve(res);
    } catch (e) {
      return Promise.reject(e);
    }
  }

  async saveReviewers(field) {
    const selected = this.store.reviewers.map((u) => u.id);

    // If there are no ids, that means we have to unassign (which is id = 0)
    // And it only accepts an array, hence [0]
    const reviewers = selected.length === 0 ? [0] : selected;
    const data = { reviewer_ids: reviewers };

    try {
      const res = await this.service.update(field, data);

      this.store.overwrite('reviewers', res.data.reviewers);
      this.store.overwrite('assignees', res.data.assignees);

      return Promise.resolve(res);
    } catch (e) {
      return Promise.reject();
    }
  }

  requestReview({ userId, callback }) {
    return this.service
      .requestReview(userId)
      .then(() => {
        this.store.updateReviewer(userId, 'reviewed');
        toast(__('Requested review'));
        callback(userId, true);
      })
      .catch(() => callback(userId, false));
  }

  setMoveToProjectId(projectId) {
    this.store.setMoveToProjectId(projectId);
  }

  fetch() {
    return this.service
      .get()
      .then(([restResponse, graphQlResponse]) => {
        this.processFetchedData(restResponse.data, graphQlResponse.data);
      })
      .catch(() =>
        createFlash({
          message: __('Error occurred when fetching sidebar data'),
        }),
      );
  }

  processFetchedData(data) {
    this.store.setAssigneeData(data);
    this.store.setReviewerData(data);
    this.store.setTimeTrackingData(data);
  }

  fetchAutocompleteProjects(searchTerm) {
    return this.service.getProjectsAutocomplete(searchTerm).then(({ data }) => {
      this.store.setAutocompleteProjects(data);
      return this.store.autocompleteProjects;
    });
  }

  moveIssue() {
    return this.service.moveIssue(this.store.moveToProjectId).then(({ data }) => {
      if (window.location.pathname !== data.web_url) {
        visitUrl(data.web_url);
      }
    });
  }
}
