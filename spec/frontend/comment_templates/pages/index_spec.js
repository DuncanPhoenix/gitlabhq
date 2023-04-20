import Vue from 'vue';
import { mount } from '@vue/test-utils';
import VueApollo from 'vue-apollo';
import savedRepliesResponse from 'test_fixtures/graphql/comment_templates/saved_replies.query.graphql.json';
import createMockApollo from 'helpers/mock_apollo_helper';
import waitForPromises from 'helpers/wait_for_promises';
import IndexPage from '~/comment_templates/pages/index.vue';
import ListItem from '~/comment_templates/components/list_item.vue';
import savedRepliesQuery from '~/comment_templates/queries/saved_replies.query.graphql';

let wrapper;

function createMockApolloProvider(response) {
  Vue.use(VueApollo);

  const requestHandlers = [[savedRepliesQuery, jest.fn().mockResolvedValue(response)]];

  return createMockApollo(requestHandlers);
}

function createComponent(options = {}) {
  const { mockApollo } = options;

  return mount(IndexPage, {
    apolloProvider: mockApollo,
  });
}

describe('Comment templates index page component', () => {
  it('renders list of comment templates', async () => {
    const mockApollo = createMockApolloProvider(savedRepliesResponse);
    const savedReplies = savedRepliesResponse.data.currentUser.savedReplies.nodes;
    wrapper = createComponent({ mockApollo });

    await waitForPromises();

    expect(wrapper.findAllComponents(ListItem).length).toBe(2);
    expect(wrapper.findAllComponents(ListItem).at(0).props('template')).toEqual(
      expect.objectContaining(savedReplies[0]),
    );
    expect(wrapper.findAllComponents(ListItem).at(1).props('template')).toEqual(
      expect.objectContaining(savedReplies[1]),
    );
  });
});
