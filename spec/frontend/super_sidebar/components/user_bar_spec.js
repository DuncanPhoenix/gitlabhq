import { shallowMountExtended } from 'helpers/vue_test_utils_helper';
import { __ } from '~/locale';
import CreateMenu from '~/super_sidebar/components/create_menu.vue';
import MergeRequestMenu from '~/super_sidebar/components/merge_request_menu.vue';
import Counter from '~/super_sidebar/components/counter.vue';
import UserBar from '~/super_sidebar/components/user_bar.vue';
import { sidebarData } from '../mock_data';

describe('UserBar component', () => {
  let wrapper;

  const findCreateMenu = () => wrapper.findComponent(CreateMenu);
  const findCounter = (at) => wrapper.findAllComponents(Counter).at(at);
  const findMergeRequestMenu = () => wrapper.findComponent(MergeRequestMenu);

  const createWrapper = (props = {}) => {
    wrapper = shallowMountExtended(UserBar, {
      propsData: {
        sidebarData,
        ...props,
      },
      provide: {
        rootPath: '/',
        toggleNewNavEndpoint: '/-/profile/preferences',
      },
    });
  };

  describe('default', () => {
    beforeEach(() => {
      createWrapper();
    });

    it('passes the "Create new..." menu groups to the create-menu component', () => {
      expect(findCreateMenu().props('groups')).toBe(sidebarData.create_new_menu_groups);
    });

    it('passes the "Merge request" menu groups to the merge_request_menu component', () => {
      expect(findMergeRequestMenu().props('items')).toBe(sidebarData.merge_request_menu);
    });

    it('renders issues counter', () => {
      expect(findCounter(0).props('count')).toBe(sidebarData.assigned_open_issues_count);
      expect(findCounter(0).props('href')).toBe(sidebarData.issues_dashboard_path);
      expect(findCounter(0).props('label')).toBe(__('Issues'));
    });

    it('renders merge requests counter', () => {
      expect(findCounter(1).props('count')).toBe(sidebarData.total_merge_requests_count);
      expect(findCounter(1).props('label')).toBe(__('Merge requests'));
    });

    it('renders todos counter', () => {
      expect(findCounter(2).props('count')).toBe(sidebarData.todos_pending_count);
      expect(findCounter(2).props('href')).toBe('/dashboard/todos');
      expect(findCounter(2).props('label')).toBe(__('To-Do list'));
    });
  });
});
