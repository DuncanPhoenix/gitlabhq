import { WIDGET_TYPE_HIERARCHY } from '~/work_items/constants';
import {
  addHierarchyChild,
  removeHierarchyChild,
  addHierarchyChildren,
} from '~/work_items/graphql/cache_utils';
import getWorkItemTreeQuery from '~/work_items/graphql/work_item_tree.query.graphql';
import { workItemHierarchyResponse, childrenWorkItems } from '../mock_data';

describe('work items graphql cache utils', () => {
  const id = 'gid://gitlab/WorkItem/10';
  const mockCacheData = {
    workItem: {
      id: 'gid://gitlab/WorkItem/10',
      title: 'Work item',
      widgets: [
        {
          type: WIDGET_TYPE_HIERARCHY,
          children: {
            nodes: [
              {
                id: 'gid://gitlab/WorkItem/20',
                title: 'Child',
              },
            ],
          },
        },
      ],
    },
  };

  describe('addHierarchyChild', () => {
    it('updates the work item with a new child', () => {
      const mockCache = {
        readQuery: () => mockCacheData,
        writeQuery: jest.fn(),
      };

      const child = {
        id: 'gid://gitlab/WorkItem/30',
        title: 'New child',
      };

      addHierarchyChild({ cache: mockCache, id, workItem: child });

      expect(mockCache.writeQuery).toHaveBeenCalledWith({
        query: getWorkItemTreeQuery,
        variables: { id },
        data: {
          workItem: {
            id: 'gid://gitlab/WorkItem/10',
            title: 'Work item',
            widgets: [
              {
                type: WIDGET_TYPE_HIERARCHY,
                children: {
                  nodes: [
                    child,
                    {
                      id: 'gid://gitlab/WorkItem/20',
                      title: 'Child',
                    },
                  ],
                },
              },
            ],
          },
        },
      });
    });

    it('does not update the work item when there is no cache data', () => {
      const mockCache = {
        readQuery: () => {},
        writeQuery: jest.fn(),
      };

      const child = {
        id: 'gid://gitlab/WorkItem/30',
        title: 'New child',
      };

      addHierarchyChild({ cache: mockCache, id, workItem: child });

      expect(mockCache.writeQuery).not.toHaveBeenCalled();
    });
  });

  describe('addHierarchyChildren', () => {
    it('updates the work item with new children', () => {
      const mockCache = {
        readQuery: () => mockCacheData,
        writeQuery: jest.fn(),
      };

      addHierarchyChildren({
        cache: mockCache,
        id,
        workItem: workItemHierarchyResponse.data.workspace.workItem,
        newItemsToAddCount: 2,
      });

      expect(mockCache.writeQuery).toHaveBeenCalledWith({
        query: getWorkItemTreeQuery,
        variables: { id },
        data: {
          workItem: {
            id: 'gid://gitlab/WorkItem/10',
            title: 'Work item',
            widgets: [
              {
                type: WIDGET_TYPE_HIERARCHY,
                children: {
                  nodes: [
                    childrenWorkItems[1],
                    childrenWorkItems[0],
                    {
                      id: 'gid://gitlab/WorkItem/20',
                      title: 'Child',
                    },
                  ],
                },
              },
            ],
          },
        },
      });
    });

    it('does not update the work item when there is no cache data', () => {
      const mockCache = {
        readQuery: () => {},
        writeQuery: jest.fn(),
      };

      const children = [
        {
          id: 'gid://gitlab/WorkItem/30',
          title: 'New child 1',
        },
        {
          id: 'gid://gitlab/WorkItem/31',
          title: 'New child 3',
        },
      ];

      addHierarchyChildren({ cache: mockCache, id, workItem: children });

      expect(mockCache.writeQuery).not.toHaveBeenCalled();
    });
  });

  describe('removeHierarchyChild', () => {
    it('updates the work item with a new child', () => {
      const mockCache = {
        readQuery: () => mockCacheData,
        writeQuery: jest.fn(),
      };

      const childToRemove = {
        id: 'gid://gitlab/WorkItem/20',
        title: 'Child',
      };

      removeHierarchyChild({ cache: mockCache, id, workItem: childToRemove });

      expect(mockCache.writeQuery).toHaveBeenCalledWith({
        query: getWorkItemTreeQuery,
        variables: { id },
        data: {
          workItem: {
            id: 'gid://gitlab/WorkItem/10',
            title: 'Work item',
            widgets: [
              {
                type: WIDGET_TYPE_HIERARCHY,
                children: {
                  nodes: [],
                },
              },
            ],
          },
        },
      });
    });

    it('does not update the work item when there is no cache data', () => {
      const mockCache = {
        readQuery: () => {},
        writeQuery: jest.fn(),
      };

      const childToRemove = {
        id: 'gid://gitlab/WorkItem/20',
        title: 'Child',
      };

      removeHierarchyChild({ cache: mockCache, id, workItem: childToRemove });

      expect(mockCache.writeQuery).not.toHaveBeenCalled();
    });
  });
});
